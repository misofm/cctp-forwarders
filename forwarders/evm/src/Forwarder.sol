// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {LibClone} from "solady/utils/LibClone.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ITokenMessengerV2 {
    function localMinter() external view returns (address);
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
}

/// @notice Keyless USDC forwarders to Sui through Circle CCTP V2 Standard
/// Transfer. One instance per chain, deployed through the keyless CREATE2
/// deployer. Each deposit address is a 77-byte Solady `LibClone` clone of
/// this instance (ERC-1167 with the 32-byte Sui recipient appended to its
/// code), created with CREATE2 by this instance with salt = recipient.
/// @dev No owner, storage, initializer or upgrade path. A clone runs
/// `forward()` by `DELEGATECALL`, so the clone holds the USDC, approves it
/// and is Circle's depositor and `messageSender`. The recipient is read from
/// the executing account's own code, never from calldata or storage.
contract Forwarder {
    uint32 internal constant SUI_DOMAIN = 8;
    /// @dev CCTP V2 Standard Transfer.
    uint32 internal constant MIN_FINALITY_THRESHOLD = 2000;

    address internal immutable usdc;
    address internal immutable messenger;

    error WrongChain();
    error FeeAboveCeiling();

    /// @dev `chainId` is a constructor argument so that this contract's
    /// CREATE2 address commits to the chain it can be deployed on.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address usdc_, address messenger_, uint256 chainId) {
        if (chainId != block.chainid) revert WrongChain();
        usdc = usdc_;
        messenger = messenger_;
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
        (bool ok, uint256 minter) = _read(messenger, abi.encodeCall(ITokenMessengerV2.localMinter, ()));
        if (ok) {
            uint256 limit;
            // forge-lint: disable-next-line(unsafe-typecast)
            (ok, limit) = _read(address(uint160(minter)), abi.encodeCall(ITokenMinterV2.burnLimitsPerMessage, (usdc)));
            if (ok && limit < amount) amount = limit;
        }
        (, uint256 maxFee) = _read(messenger, abi.encodeCall(ITokenMessengerV2.getMinFeeAmount, (amount)));
        if (maxFee > amount / 100) revert FeeAboveCeiling();

        // FiatToken returns true or reverts; Circle's `transferFrom` needs the allowance.
        // forge-lint: disable-next-line(unused-return)
        IUSDC(usdc).approve(messenger, amount);
        ITokenMessengerV2(messenger)
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
