// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Forwarder} from "../../src/Forwarder.sol";
import {Chains} from "../../script/Chains.sol";

/// @dev The parts of Circle's deployed FiatToken (circlefin/stablecoin-evm)
/// and CCTP V2 contracts (circlefin/evm-cctp-contracts) the tests use.
interface IFiatToken {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 allowed) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function blacklister() external view returns (address);
    function blacklist(address) external;
    function unBlacklist(address) external;
}

interface IPausable {
    function pauser() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface ITokenMessenger {
    function owner() external view returns (address);
    function denylister() external view returns (address);
    function denylist(address) external;
    function unDenylist(address) external;
    function addRemoteTokenMessenger(uint32 domain, bytes32 tokenMessenger) external;
    function removeRemoteTokenMessenger(uint32 domain) external;
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);
    function localMinter() external view returns (address);
    function localMessageTransmitter() external view returns (address);
    function messageBodyVersion() external view returns (uint32);
}

interface ITokenMinter {
    function tokenController() external view returns (address);
    function setMaxBurnAmountPerMessage(address token, uint256 limit) external;
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

interface IMessageTransmitter {
    function localDomain() external view returns (uint32);
    function version() external view returns (uint32);
}

/// @notice Every fork scenario, once per supported chain, on a local fork at
/// the pinned block. Circle's privileged roles are read from the chain and
/// impersonated on the fork only. Nothing on Sui is exercised: the fork ends
/// at the `MessageSent` event.
abstract contract ForkTest is Test {
    using stdJson for string;

    bytes32 constant MESSAGE_SENT = keccak256("MessageSent(bytes)");
    bytes32 constant DEPOSIT_FOR_BURN =
        keccak256("DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)");
    /// @dev First and last bytes non-zero so truncation or padding mistakes show.
    bytes32 constant SUI_RECIPIENT = 0xa7c1e5d2f40b9e6c3d8a1b2c4e6f80913a5b7c9d1e2f40618293a4b5c6d7e8f9;

    Chains.Chain c;
    Forwarder instance;
    IFiatToken usdc;
    ITokenMessenger tm;
    address fundingMinter;
    bool noFork;

    function chain() internal pure virtual returns (Chains.Chain memory);

    function setUp() public {
        c = chain();
        try vm.createSelectFork(vm.envOr(c.rpcEnvVar, c.defaultRpc), c.forkBlock) {}
        catch {
            if (vm.envOr("REQUIRE_FORK", false)) {
                revert(
                    string.concat("REQUIRE_FORK=1 but the ", c.name, " fork could not be created: check ", c.rpcEnvVar)
                );
            }
            noFork = true;
            return;
        }
        usdc = IFiatToken(c.usdc);
        tm = ITokenMessenger(c.tokenMessenger);

        (bool ok, bytes memory ret) = Chains.CREATE2_DEPLOYER.call(abi.encodePacked(Chains.SALT, Chains.initCode(c)));
        assertTrue(ok, "keyless deployment");
        instance = Forwarder(address(bytes20(ret)));
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/fixtures/address-vectors.json"));
        assertEq(address(instance), json.readAddress(string.concat(".chains.", c.name, ".factory")), "fixture factory");

        // Test USDC comes from FiatToken's own minting path.
        fundingMinter = makeAddr("fundingMinter");
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(fundingMinter, type(uint256).max);
    }

    modifier forked() {
        if (noFork) vm.skip(true);
        _;
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function _fund(address to, uint256 amount) internal {
        vm.prank(fundingMinter);
        usdc.mint(to, amount);
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _word(bytes memory m, uint256 offset) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(m, 32), offset))
        }
    }

    function _u32(bytes memory m, uint256 offset) internal pure returns (uint256) {
        return uint256(_word(m, offset)) >> 224;
    }

    function _singleLog(Vm.Log[] memory logs, bytes32 topic0, address emitter) internal pure returns (Vm.Log memory l) {
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                l = logs[i];
                n++;
            }
        }
        assertEq(n, 1, "exactly one matching log");
    }

    function _cloneRuntime(bytes32 r) internal view returns (bytes memory) {
        return abi.encodePacked(hex"363d3d373d3d3d363d73", address(instance), hex"5af43d82803e903d91602b57fd5bf3", r);
    }

    /// @dev The `MessageSent` (MessageV2 header ‖ BurnMessageV2 body, offsets
    /// from Circle's MessageV2.sol / BurnMessageV2.sol) and `DepositForBurn`
    /// of one crank of `fwd`.
    function _assertCrankLogs(Vm.Log[] memory logs, address fwd, bytes32 r, uint256 amount) internal view {
        bytes memory m = abi.decode(_singleLog(logs, MESSAGE_SENT, c.messageTransmitter).data, (bytes));
        assertEq(m.length, 376, "148-byte header + 228-byte body, no hookData");
        assertEq(_u32(m, 0), 1, "version");
        assertEq(_u32(m, 4), c.localDomain, "sourceDomain");
        assertEq(_u32(m, 8), Chains.SUI_DOMAIN, "destinationDomain");
        assertEq(_word(m, 12), bytes32(0), "nonce (assigned off-chain)");
        assertEq(_word(m, 44), _b32(c.tokenMessenger), "sender");
        assertEq(_word(m, 76), Chains.SUI_REMOTE_TOKEN_MESSENGER, "recipient");
        assertEq(_word(m, 108), bytes32(0), "destinationCaller");
        assertEq(_u32(m, 140), 2000, "minFinalityThreshold");
        assertEq(_u32(m, 144), 0, "finalityThresholdExecuted");
        assertEq(_u32(m, 148), 1, "body version");
        assertEq(_word(m, 152), _b32(c.usdc), "burnToken");
        assertEq(_word(m, 184), r, "mintRecipient");
        assertEq(uint256(_word(m, 216)), amount, "amount");
        assertEq(_word(m, 248), _b32(fwd), "messageSender");
        assertEq(_word(m, 280), bytes32(0), "maxFee");
        assertEq(_word(m, 312), bytes32(0), "feeExecuted");
        assertEq(_word(m, 344), bytes32(0), "expirationBlock");

        Vm.Log memory d = _singleLog(logs, DEPOSIT_FOR_BURN, c.tokenMessenger);
        assertEq(d.topics[1], _b32(c.usdc), "indexed burnToken");
        assertEq(d.topics[2], _b32(fwd), "indexed depositor");
        assertEq(d.topics[3], bytes32(uint256(2000)), "indexed minFinalityThreshold");
        (uint256 dAmount, bytes32 dRecipient, uint32 dDomain, bytes32 dMessenger, bytes32 dCaller, uint256 dFee,) =
            abi.decode(d.data, (uint256, bytes32, uint32, bytes32, bytes32, uint256, bytes));
        assertEq(dAmount, amount);
        assertEq(dRecipient, r);
        assertEq(dDomain, Chains.SUI_DOMAIN);
        assertEq(dMessenger, Chains.SUI_REMOTE_TOKEN_MESSENGER);
        assertEq(dCaller, bytes32(0));
        assertEq(dFee, 0);
    }

    /// @dev A first crank of `r` reverts with exactly `reason`; funds wait.
    function _expectFirstCrankWaits(bytes32 r, uint256 balance, bytes memory reason) internal {
        address fwd = instance.addressOf(r);
        uint256 supply = usdc.totalSupply();
        vm.expectRevert(reason);
        instance.forward(r);
        assertEq(usdc.balanceOf(fwd), balance, "balance intact");
        assertEq(fwd.code.length, 0, "deployment rolled back");
        assertEq(usdc.totalSupply(), supply, "nothing burned");
    }

    function _expectCrankSucceeds(bytes32 r, uint256 balance) internal {
        address fwd = instance.addressOf(r);
        uint256 supply = usdc.totalSupply();
        instance.forward(r);
        assertEq(usdc.balanceOf(fwd), 0, "swept");
        assertEq(supply - usdc.totalSupply(), balance, "burned");
    }

    function _fundedRecipient(uint256 seed, uint256 amount) internal returns (bytes32 r) {
        r = keccak256(abi.encode(seed));
        _fund(instance.addressOf(r), amount);
    }

    // ---------------------------------------------------------------
    // chain state and deployment
    // ---------------------------------------------------------------

    function test_chainState() public forked {
        assertEq(block.chainid, c.chainId, "chain id");
        assertEq(tm.localMinter(), c.tokenMinter, "localMinter");
        assertEq(tm.localMessageTransmitter(), c.messageTransmitter, "localMessageTransmitter");
        assertEq(IMessageTransmitter(c.messageTransmitter).localDomain(), c.localDomain, "localDomain");
        assertEq(IMessageTransmitter(c.messageTransmitter).version(), 1, "message version");
        assertEq(tm.messageBodyVersion(), 1, "body version");
        assertEq(tm.remoteTokenMessengers(Chains.SUI_DOMAIN), Chains.SUI_REMOTE_TOKEN_MESSENGER, "Sui registered");
        // Sui's MessageTransmitterV2 accepts as header recipient keccak256 of
        // the TokenMessengerMinterV2 authenticator's full type name (package id
        // as 64 lowercase hex digits without 0x).
        string memory pkg = vm.toString(Chains.SUI_TOKEN_MESSENGER_MINTER_V2_PACKAGE);
        assertEq(
            keccak256(
                abi.encodePacked(
                    vm.replace(pkg, "0x", ""), "::message_transmitter_authenticator::MessageTransmitterAuthenticator"
                )
            ),
            Chains.SUI_REMOTE_TOKEN_MESSENGER,
            "Sui messenger re-derived"
        );
        assertEq(ITokenMinter(c.tokenMinter).burnLimitsPerMessage(c.usdc), 1e13, "burn limit (10M USDC)");
        (bool ok,) = c.tokenMessenger.staticcall(abi.encodeWithSignature("getMinFeeAmount(uint256)", 1e6));
        assertFalse(ok, "getMinFeeAmount absent");
        assertEq(usdc.decimals(), 6, "decimals");
        assertGt(Chains.CREATE2_DEPLOYER.code.length, 0, "keyless deployer present");
    }

    function test_keylessDeploy_otherChainId_fails() public forked {
        Chains.Chain memory other = c.chainId == 137 ? Chains.avalanche() : Chains.polygon();
        bytes memory init = Chains.initCode(other);
        (bool ok,) = Chains.CREATE2_DEPLOYER.call(abi.encodePacked(Chains.SALT, init));
        assertFalse(ok, "WrongChain");
        assertEq(vm.computeCreate2Address(Chains.SALT, keccak256(init), Chains.CREATE2_DEPLOYER).code.length, 0);
    }

    // ---------------------------------------------------------------
    // forwarding
    // ---------------------------------------------------------------

    function test_sui_happyPath() public forked {
        bytes32 r = SUI_RECIPIENT;
        address fwd = instance.addressOf(r);
        assertEq(fwd.code.length, 0);
        _fund(fwd, 25e6);
        uint256 supply = usdc.totalSupply();

        address cranker = makeAddr("cranker");
        vm.recordLogs();
        vm.prank(cranker, cranker);
        uint256 g = gasleft();
        instance.forward(r);
        console2.log(string.concat("gas[", c.name, "]: deploy + first forward via factory"), g - gasleft());
        _assertCrankLogs(vm.getRecordedLogs(), fwd, r, 25e6);
        assertEq(fwd.code, _cloneRuntime(r), "77-byte clone");
        assertEq(usdc.balanceOf(fwd), 0, "swept");
        assertEq(supply - usdc.totalSupply(), 25e6, "burned exactly");
        assertEq(usdc.allowance(fwd, c.tokenMessenger), 0, "no residual allowance");

        _fund(fwd, 1e6);
        vm.recordLogs();
        vm.prank(makeAddr("cranker2"));
        g = gasleft();
        instance.forward(r);
        console2.log(string.concat("gas[", c.name, "]: later forward via factory"), g - gasleft());
        _assertCrankLogs(vm.getRecordedLogs(), fwd, r, 1e6);
    }

    function test_laterCranks_directAndViaFactory() public forked {
        bytes32 r = _fundedRecipient(1, 5e6);
        address fwd = instance.addressOf(r);
        instance.forward(r);

        _fund(fwd, 10e6);
        vm.recordLogs();
        vm.prank(makeAddr("directCaller"));
        uint256 g = gasleft();
        Forwarder(fwd).forward();
        console2.log(string.concat("gas[", c.name, "]: later forward direct"), g - gasleft());
        _assertCrankLogs(vm.getRecordedLogs(), fwd, r, 10e6);

        _fund(fwd, 3e6);
        vm.recordLogs();
        instance.forward(r);
        _assertCrankLogs(vm.getRecordedLogs(), fwd, r, 3e6);
        assertEq(fwd.code, _cloneRuntime(r));
        assertEq(usdc.allowance(fwd, c.tokenMessenger), 0);
    }

    function test_burnLimitLowered_drainsInChunks() public forked {
        vm.prank(ITokenMinter(c.tokenMinter).tokenController());
        ITokenMinter(c.tokenMinter).setMaxBurnAmountPerMessage(c.usdc, 50e6);
        bytes32 r = _fundedRecipient(2, 120e6);
        address fwd = instance.addressOf(r);
        instance.forward(r);
        assertEq(usdc.balanceOf(fwd), 70e6);
        instance.forward(r);
        assertEq(usdc.balanceOf(fwd), 20e6);
        Forwarder(fwd).forward();
        assertEq(usdc.balanceOf(fwd), 0);
    }

    // ---------------------------------------------------------------
    // Circle refuses: funds wait, then forward once lifted
    // ---------------------------------------------------------------

    function test_suiRouteRemoved_fundsWait() public forked {
        vm.prank(tm.owner());
        tm.removeRemoteTokenMessenger(Chains.SUI_DOMAIN);
        bytes32 r = _fundedRecipient(3, 25e6);
        _expectFirstCrankWaits(r, 25e6, "No TokenMessenger for domain");
        vm.prank(tm.owner());
        tm.addRemoteTokenMessenger(Chains.SUI_DOMAIN, Chains.SUI_REMOTE_TOKEN_MESSENGER);
        _expectCrankSucceeds(r, 25e6);
    }

    /// @dev TokenMinter.burn, MessageTransmitterV2.sendMessage and USDC's
    /// own approve all revert "Pausable: paused".
    function _pausedFundsWait(address pausable, uint256 seed) internal {
        bytes32 r = _fundedRecipient(seed, 10e6); // before the pause: USDC minting pauses too
        address pauser = IPausable(pausable).pauser();
        vm.prank(pauser);
        IPausable(pausable).pause();
        _expectFirstCrankWaits(r, 10e6, "Pausable: paused");
        vm.prank(pauser);
        IPausable(pausable).unpause();
        _expectCrankSucceeds(r, 10e6);
    }

    function test_minterPaused_fundsWait() public forked {
        _pausedFundsWait(c.tokenMinter, 4);
    }

    function test_messageTransmitterPaused_fundsWait() public forked {
        _pausedFundsWait(c.messageTransmitter, 5);
    }

    function test_usdcPaused_fundsWait() public forked {
        _pausedFundsWait(c.usdc, 6);
    }

    function test_usdcBlacklistedForwarder_fundsWait() public forked {
        bytes32 r = _fundedRecipient(7, 10e6);
        address fwd = instance.addressOf(r);
        vm.prank(usdc.blacklister());
        usdc.blacklist(fwd);
        _expectFirstCrankWaits(r, 10e6, "Blacklistable: account is blacklisted");
        vm.prank(usdc.blacklister());
        usdc.unBlacklist(fwd);
        _expectCrankSucceeds(r, 10e6);
    }

    function test_denylistedForwarder_fundsWait() public forked {
        bytes32 r = _fundedRecipient(8, 10e6);
        address fwd = instance.addressOf(r);
        vm.prank(tm.denylister());
        tm.denylist(fwd);
        _expectFirstCrankWaits(r, 10e6, "Denylistable: account is on denylist");
        vm.prank(tm.denylister());
        tm.unDenylist(fwd);
        _expectCrankSucceeds(r, 10e6);
    }

    /// @dev Circle's denylist also checks tx.origin.
    function test_denylistedCranker_blocksOnlyThemselves() public forked {
        bytes32 r = _fundedRecipient(9, 10e6);
        address blocked = makeAddr("blockedCranker");
        vm.prank(tm.denylister());
        tm.denylist(blocked);
        vm.startPrank(blocked, blocked);
        _expectFirstCrankWaits(r, 10e6, "Denylistable: account is on denylist");
        vm.stopPrank();
        vm.startPrank(makeAddr("okCranker"), makeAddr("okCranker"));
        _expectCrankSucceeds(r, 10e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // edge cases
    // ---------------------------------------------------------------

    function test_zeroRecipient_circleRefuses_fundsWait() public forked {
        _fund(instance.addressOf(bytes32(0)), 10e6);
        _expectFirstCrankWaits(bytes32(0), 10e6, "Mint recipient must be nonzero");
    }

    /// @dev An EOA delegating (EIP-7702) to the instance or to a clone runs
    /// `forward()` in its own context, but EXTCODECOPY of a delegated account
    /// returns its 23-byte designator `0xef0100 ‖ target`, so the recipient
    /// read at 0x2d is zero and Circle refuses.
    function test_eip7702_delegatedEoa_cannotBurn() public forked {
        vm.setEvmVersion("prague");
        bytes32 r = _fundedRecipient(10, 1e6);
        instance.forward(r);
        address[2] memory targets = [address(instance), instance.addressOf(r)];
        for (uint256 i; i < 2; i++) {
            (address eoa, uint256 pk) = makeAddrAndKey(string.concat("delegatingEoa", vm.toString(i)));
            vm.signAndAttachDelegation(targets[i], pk);
            Forwarder(eoa).addressOf(r); // carries the authorization
            assertEq(eoa.code, abi.encodePacked(hex"ef0100", targets[i]), "EXTCODECOPY = designator");
            _fund(eoa, 5e6);
            vm.prank(makeAddr("unrelated"), makeAddr("unrelated"));
            vm.expectRevert("Mint recipient must be nonzero");
            Forwarder(eoa).forward();
            assertEq(usdc.balanceOf(eoa), 5e6, "balance intact");
        }
    }

    /// @dev Accepted behaviour: the instance is not a deposit address, but
    /// `forward()` on it burns USDC stranded at the instance to whatever its
    /// own code holds at [0x2d, 0x4d).
    function test_instanceDirectForward_burnsOnlyItsOwnStrayUsdc() public forked {
        bytes32 codeWord = _word(address(instance).code, 0x2d);
        _fund(address(instance), 2e6);
        vm.recordLogs();
        instance.forward();
        Vm.Log memory d = _singleLog(vm.getRecordedLogs(), DEPOSIT_FOR_BURN, c.tokenMessenger);
        (, bytes32 mintRecipient) = abi.decode(d.data, (uint256, bytes32));
        assertEq(mintRecipient, codeWord, "mintRecipient = instance code [0x2d, 0x4d)");
        assertEq(d.topics[2], _b32(address(instance)), "depositor = instance");
        assertEq(usdc.balanceOf(address(instance)), 0);
    }
}

/// @notice Set AVALANCHE_RPC_URL to use another archive endpoint.
contract AvalancheForkTest is ForkTest {
    function chain() internal pure override returns (Chains.Chain memory) {
        return Chains.avalanche();
    }
}

/// @notice Set POLYGON_RPC_URL to use another archive endpoint.
contract PolygonForkTest is ForkTest {
    function chain() internal pure override returns (Chains.Chain memory) {
        return Chains.polygon();
    }
}
