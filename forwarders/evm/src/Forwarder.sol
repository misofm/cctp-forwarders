// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {LibClone} from "solady/utils/LibClone.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ITokenMessengerV2 {
    function localMinter() external view returns (address);
    function localMessageTransmitter() external view returns (address);
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);
    function getMinFeeAmount(uint256 amount) external view returns (uint256);
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

interface ITokenMinterV2 {
    function burnLimitsPerMessage(address token) external view returns (uint256);
    function localTokenMessenger() external view returns (address);
    function getLocalToken(uint32 remoteDomain, bytes32 remoteToken) external view returns (address);
}

interface IMessageTransmitterV2 {
    function localDomain() external view returns (uint32);
}

/// @notice Keyless USDC forwarders to Sui through Circle CCTP V2 Standard
/// Transfer. One instance per chain, deployed through the keyless CREATE2
/// deployer from the same init code on every chain, so the instance and
/// every deposit address have the same address on every chain. Each deposit
/// address is a 77-byte Solady `LibClone` clone of this instance (ERC-1167
/// with the 32-byte Sui recipient appended to its code), created with CREATE2
/// by this instance with salt = recipient.
/// @dev No owner, storage, initializer or upgrade path. A clone runs
/// `forward()` by `DELEGATECALL`, so the clone holds the USDC, approves it
/// and is Circle's depositor and `messageSender`. The recipient is read from
/// the executing account's own code, never from calldata or storage.
contract Forwarder {
    uint32 internal constant SUI_DOMAIN = 8;
    /// @dev CCTP V2 Standard Transfer.
    uint32 internal constant MIN_FINALITY_THRESHOLD = 2000;
    /// @dev Circle's TokenMessengerV2, at this address on every EVM chain it serves.
    address internal constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    /// @dev Sui USDC's CCTP token id, which Circle's TokenMinterV2 maps to
    /// the chain's native USDC.
    bytes32 internal constant SUI_USDC = 0x3f2e28d163e25042ac7c9543c15675af5aa5d3c27dbc656a67f37f4293a3fdef;

    address internal immutable usdc;

    error SuiDomain();
    error NoSuiRoute();
    error MinterNotLinked();
    error NoUsdc();
    error NoBurnLimit();
    error FeeAboveCeiling();

    /// @dev Takes no arguments so the init code is identical on every chain.
    /// Deployment succeeds only where Circle's messenger routes native USDC
    /// to Sui.
    constructor() {
        ITokenMessengerV2 messenger = ITokenMessengerV2(MESSENGER);
        if (IMessageTransmitterV2(messenger.localMessageTransmitter()).localDomain() == SUI_DOMAIN) revert SuiDomain();
        if (messenger.remoteTokenMessengers(SUI_DOMAIN) == bytes32(0)) revert NoSuiRoute();
        ITokenMinterV2 minter = ITokenMinterV2(messenger.localMinter());
        if (minter.localTokenMessenger() != MESSENGER) revert MinterNotLinked();
        address usdc_ = minter.getLocalToken(SUI_DOMAIN, SUI_USDC);
        if (usdc_.code.length == 0) revert NoUsdc();
        if (minter.burnLimitsPerMessage(usdc_) == 0) revert NoBurnLimit();
        usdc = usdc_;
    }

    /// @notice The deposit address of `recipient`, a 32-byte Sui address.
    function addressOf(bytes32 recipient) external view returns (address) {
        return
            LibClone.predictDeterministicAddress(address(this), abi.encodePacked(recipient), recipient, address(this));
    }

    /// @notice Deploys `recipient`'s deposit address if it has no code yet,
    /// then calls `forward()` on it.
    function forward(bytes32 recipient) external {
        (, address forwarder) = LibClone.createDeterministicClone(address(this), abi.encodePacked(recipient), recipient);
        Forwarder(forwarder).forward();
    }

    /// @notice On a deposit address: burns its USDC, up to Circle's
    /// per-message limit, to its recipient on Sui. Callable by anyone.
    function forward() external {
        bytes32 recipient;
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, 0x2d, 0x20)
            recipient := mload(0x00)
        }
        // Circle's per-message limit and on-chain minimum fee are read
        // best-effort: a failed or short read means no limit and no minimum,
        // so a change to Circle's view functions cannot strand funds. Circle's
        // `depositForBurn` enforces both independently.
        uint256 amount = IUSDC(usdc).balanceOf(address(this));
        (bool ok, uint256 minter) = _read(MESSENGER, abi.encodeCall(ITokenMessengerV2.localMinter, ()));
        if (ok) {
            uint256 limit;
            // forge-lint: disable-next-line(unsafe-typecast)
            (ok, limit) = _read(address(uint160(minter)), abi.encodeCall(ITokenMinterV2.burnLimitsPerMessage, (usdc)));
            if (ok && limit < amount) amount = limit;
        }
        (, uint256 maxFee) = _read(MESSENGER, abi.encodeCall(ITokenMessengerV2.getMinFeeAmount, (amount)));
        if (maxFee > amount / 100) revert FeeAboveCeiling();

        // FiatToken returns true or reverts; Circle's `transferFrom` needs the allowance.
        // forge-lint: disable-next-line(unused-return)
        IUSDC(usdc).approve(MESSENGER, amount);
        ITokenMessengerV2(MESSENGER)
            .depositForBurn(amount, SUI_DOMAIN, recipient, usdc, bytes32(0), maxFee, MIN_FINALITY_THRESHOLD);
    }

    /// @dev The first word returned by a successful static call, if any.
    function _read(address target, bytes memory data) private view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = target.staticcall(data);
        ok = ok && ret.length >= 32;
        if (ok) value = abi.decode(ret, (uint256));
    }
}
