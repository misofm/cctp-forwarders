// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Forwarder, ITokenMessengerV2} from "../src/Forwarder.sol";
import {Chains} from "../script/Chains.sol";
import {WriteAddressVectors} from "../script/WriteAddressVectors.s.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: transfer amount exceeds allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

/// @dev TokenMinter: `burn` behind Circle's `onlyWithinBurnLimit`.
contract MockMinter {
    uint256 public limit = 1e13;

    function setLimit(uint256 l) external {
        limit = l;
    }

    function burnLimitsPerMessage(address) external view returns (uint256) {
        return limit;
    }

    function burn(address token, uint256 amount) external {
        require(limit > 0, "Burning token unsupported");
        require(amount <= limit, "Burn amount exceeds per tx limit");
        MockUSDC(token).burn(amount);
    }
}

/// @dev TokenMessengerV2 with `_depositForBurn`'s checks in Circle's order.
/// `getMinFeeAmount` is served from the fallback so the tests can make it
/// absent (revert) or return malformed data; the fee Circle enforces inside
/// `depositForBurn` is always `_minFeeAmount` (Circle's formula, `rate` in
/// 1/1000 bps).
contract MockMessenger {
    enum Lookup {
        Absent,
        Normal,
        Empty,
        Short,
        Long
    }

    struct Deposit {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        address sender;
    }

    MockMinter public immutable localMinter = new MockMinter();
    mapping(uint32 => bytes32) public remoteTokenMessengers;
    Lookup public lookup;
    uint256 public rate;
    Deposit public last;

    constructor() {
        remoteTokenMessengers[8] = bytes32(uint256(0x5111));
    }

    function setFee(Lookup l, uint256 r) external {
        (lookup, rate) = (l, r);
    }

    function setRemote(uint32 domain, bytes32 m) external {
        remoteTokenMessengers[domain] = m;
    }

    function _minFeeAmount(uint256 amount) internal view returns (uint256) {
        if (rate == 0) return 0;
        require(amount > 1, "Amount too low");
        uint256 fee = amount * rate / 10_000_000;
        return fee == 0 ? 1 : fee;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        require(lookup != Lookup.Absent && bytes4(data) == ITokenMessengerV2.getMinFeeAmount.selector);
        uint256 fee = _minFeeAmount(abi.decode(data[4:], (uint256)));
        if (lookup == Lookup.Empty) return "";
        if (lookup == Lookup.Short) return new bytes(31);
        if (lookup == Lookup.Long) return abi.encode(fee, type(uint256).max);
        return abi.encode(fee);
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(amount > 0, "Amount must be nonzero");
        require(mintRecipient != bytes32(0), "Mint recipient must be nonzero");
        require(maxFee < amount, "Max fee must be less than amount");
        if (rate > 0) require(maxFee >= _minFeeAmount(amount), "Insufficient max fee");
        require(remoteTokenMessengers[destinationDomain] != bytes32(0), "No TokenMessenger for domain");
        MockUSDC(burnToken).transferFrom(msg.sender, address(localMinter), amount);
        localMinter.burn(burnToken, amount);
        last = Deposit(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            msg.sender
        );
    }
}

contract ForwarderTest is Test {
    using stdJson for string;

    bytes32 constant R = 0xa7c1e5d2f40b9e6c3d8a1b2c4e6f80913a5b7c9d1e2f40618293a4b5c6d7e8f9;

    MockUSDC usdc;
    MockMessenger messenger;
    Forwarder factory;

    function setUp() public {
        usdc = new MockUSDC();
        messenger = new MockMessenger();
        factory = new Forwarder(address(usdc), address(messenger), block.chainid);
    }

    function _last() internal view returns (MockMessenger.Deposit memory d) {
        (
            d.amount,
            d.destinationDomain,
            d.mintRecipient,
            d.burnToken,
            d.destinationCaller,
            d.maxFee,
            d.minFinalityThreshold,
            d.sender
        ) = messenger.last();
    }

    /// @dev Funds `r`'s address with `amount`, cranks it through the factory
    /// and returns the `maxFee` Circle received.
    function _crank(bytes32 r, uint256 amount) internal returns (uint256) {
        usdc.mint(factory.addressOf(r), amount);
        factory.forward(r);
        return _last().maxFee;
    }

    // ---------------------------------------------------------------
    // addresses
    // ---------------------------------------------------------------

    /// @dev `fixtures/address-vectors.json` must equal what the current build
    /// produces: the instance is deployed through the keyless deployer's real
    /// runtime code and every vector is recomputed by its `addressOf`.
    function test_fixture_matchesCurrentBuild() public {
        string memory json = vm.readFile("fixtures/address-vectors.json");
        string memory hint = "stale fixture: re-run script/WriteAddressVectors.s.sol";
        vm.etch(
            Chains.CREATE2_DEPLOYER,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        assertEq(json.readAddress(".create2Deployer"), Chains.CREATE2_DEPLOYER, hint);
        assertEq(json.readBytes32(".salt"), Chains.SALT, hint);
        bytes32[6] memory rs = new WriteAddressVectors().recipients();
        Chains.Chain[2] memory cs = Chains.all();
        address[2] memory first;
        for (uint256 i; i < cs.length; i++) {
            Chains.Chain memory c = cs[i];
            string memory key = string.concat(".chains.", c.name);
            assertEq(json.readUint(string.concat(key, ".chainId")), c.chainId, hint);
            assertEq(json.readAddress(string.concat(key, ".usdc")), c.usdc, hint);
            assertEq(json.readAddress(string.concat(key, ".messenger")), c.tokenMessenger, hint);
            assertEq(json.readBytes32(string.concat(key, ".initCodeHash")), keccak256(Chains.initCode(c)), hint);

            vm.chainId(c.chainId);
            (bool ok, bytes memory ret) =
                Chains.CREATE2_DEPLOYER.call(abi.encodePacked(Chains.SALT, Chains.initCode(c)));
            assertTrue(ok && ret.length == 20, "keyless deployment");
            Forwarder instance = Forwarder(address(bytes20(ret)));
            assertEq(json.readAddress(string.concat(key, ".factory")), address(instance), hint);

            assertFalse(vm.keyExistsJson(json, string.concat(key, ".vectors[6]")), hint);
            for (uint256 v; v < rs.length; v++) {
                string memory vkey = string.concat(key, ".vectors[", vm.toString(v), "]");
                assertEq(json.readBytes32(string.concat(vkey, ".recipient")), rs[v], hint);
                assertEq(json.readAddress(string.concat(vkey, ".address")), instance.addressOf(rs[v]), hint);
            }
            first[i] = instance.addressOf(rs[0]);
        }
        assertTrue(first[0] != first[1], "same recipient, different address per chain");
    }

    /// @dev The deployed clone sits at `addressOf(r)` and is exactly the
    /// 77-byte ERC-1167 runtime with `r` appended (offset 0x2d).
    function testFuzz_addressOf_isDeployedClone(bytes32 r) public {
        vm.assume(r != bytes32(0));
        address predicted = factory.addressOf(r);
        assertEq(predicted.code.length, 0);
        _crank(r, 1);
        bytes memory runtime =
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(factory), hex"5af43d82803e903d91602b57fd5bf3", r);
        assertEq(runtime.length, 77);
        assertEq(predicted.code, runtime);
        assertEq(_last().sender, predicted);
    }

    function test_constructor_wrongChain_reverts() public {
        vm.expectRevert(Forwarder.WrongChain.selector);
        new Forwarder(address(usdc), address(messenger), block.chainid + 1);
    }

    /// @dev The baseline factory re-checked the chain id at forward time,
    /// which would strand USDC already sent to counterfactual addresses if the
    /// chain ever changed its id. Only the constructor checks it now.
    function test_chainIdChange_counterfactualDepositStillForwards() public {
        vm.chainId(block.chainid + 1);
        address predicted = factory.addressOf(R);
        _crank(R, 7e6);
        assertGt(predicted.code.length, 0, "deployed");
        assertEq(usdc.balanceOf(predicted), 0, "forwarded");
    }

    // ---------------------------------------------------------------
    // forward
    // ---------------------------------------------------------------

    /// @dev Each crank burns min(balance, limit) with the fixed Standard
    /// Transfer arguments; the clone is the depositor and leaves no allowance.
    function test_forward_burnsMinOfBalanceAndLimit_inChunks() public {
        messenger.localMinter().setLimit(3e6);
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 7e6);
        uint256[3] memory chunks = [uint256(3e6), 3e6, 1e6];
        for (uint256 i; i < 3; i++) {
            factory.forward(R);
            MockMessenger.Deposit memory d = _last();
            assertEq(d.amount, chunks[i], "amount");
            assertEq(d.destinationDomain, 8, "domain");
            assertEq(d.mintRecipient, R, "recipient");
            assertEq(d.burnToken, address(usdc), "token");
            assertEq(d.destinationCaller, bytes32(0), "destinationCaller");
            assertEq(d.maxFee, 0, "maxFee");
            assertEq(d.minFinalityThreshold, 2000, "threshold");
            assertEq(d.sender, fwd, "depositor");
            assertEq(usdc.allowance(fwd, address(messenger)), 0, "allowance");
        }
        assertEq(usdc.balanceOf(fwd), 0);
        assertEq(usdc.totalSupply(), 0);
        vm.expectRevert("Amount must be nonzero");
        Forwarder(fwd).forward();
    }

    /// @dev Neither the caller, tx.origin nor extra calldata can change where
    /// the USDC goes.
    function testFuzz_forward_callerAndCalldataIndependent(address caller, bytes calldata extra) public {
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 2e6);
        vm.prank(caller, caller);
        (bool ok,) = address(factory).call(abi.encodePacked(abi.encodeWithSignature("forward(bytes32)", R), extra));
        assertTrue(ok);
        assertEq(_last().mintRecipient, R);

        usdc.mint(fwd, 1e6);
        vm.prank(caller, caller);
        (ok,) = fwd.call(abi.encodePacked(abi.encodeWithSignature("forward()"), extra));
        assertTrue(ok);
        assertEq(_last().mintRecipient, R);
        assertEq(_last().sender, fwd);
        assertEq(usdc.balanceOf(fwd), 0);
    }

    function test_minFee_lookupShapes() public {
        // absent (reverts), empty or short returndata: no fee
        assertEq(_crank(bytes32(uint256(1)), 1e6), 0, "absent");
        messenger.setFee(MockMessenger.Lookup.Empty, 0);
        assertEq(_crank(bytes32(uint256(2)), 1e6), 0, "empty");
        messenger.setFee(MockMessenger.Lookup.Short, 0);
        assertEq(_crank(bytes32(uint256(3)), 1e6), 0, "short");
        // a value or longer returndata: its first word
        messenger.setFee(MockMessenger.Lookup.Normal, 5000); // 5 bps
        assertEq(_crank(bytes32(uint256(4)), 1e6), 500, "value");
        messenger.setFee(MockMessenger.Lookup.Long, 5000);
        assertEq(_crank(bytes32(uint256(5)), 1e6), 500, "long");
    }

    function test_minFee_ceilingIsOnePercent() public {
        messenger.setFee(MockMessenger.Lookup.Normal, 100_000); // exactly 1%
        assertEq(_crank(bytes32(uint256(1)), 1e8), 1e6, "1% passes");

        messenger.setFee(MockMessenger.Lookup.Normal, 100_001);
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 1e8);
        vm.expectRevert(Forwarder.FeeAboveCeiling.selector);
        factory.forward(R);
        assertEq(usdc.balanceOf(fwd), 1e8);
    }

    /// @dev Outcome derived independently from Circle's rules and the 1% cap.
    function testFuzz_forward_outcome(uint256 balance, uint256 limit, uint256 rate) public {
        balance = bound(balance, 0, 1e15);
        limit = bound(limit, 0, 1e15);
        rate = bound(rate, 0, 200_000);
        messenger.localMinter().setLimit(limit);
        messenger.setFee(MockMessenger.Lookup.Normal, rate);
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, balance);

        uint256 amount = balance < limit ? balance : limit;
        uint256 fee; // what the lookup yields; it reverts below 2 when a rate is set
        if (rate > 0 && amount > 1) fee = amount * rate / 1e7 == 0 ? 1 : amount * rate / 1e7;

        if (fee > amount / 100) vm.expectRevert(Forwarder.FeeAboveCeiling.selector);
        else if (amount == 0) vm.expectRevert("Amount must be nonzero");
        else if (rate > 0 && amount == 1) vm.expectRevert("Amount too low");
        factory.forward(R);

        bool burned = fwd.code.length > 0;
        assertEq(usdc.balanceOf(fwd), burned ? balance - amount : balance);
        if (burned) {
            assertEq(_last().amount, amount);
            assertEq(_last().maxFee, fee);
        }
    }

    /// @dev A failed or short limit read means "no limit": the whole balance
    /// is offered and Circle's own limit decides. Covers localMinter()
    /// reverting, burnLimitsPerMessage reverting, and a codeless minter.
    function test_limitLookupFails_burnsWholeBalance() public {
        MockMinter minter = messenger.localMinter();
        for (uint256 i; i < 3; i++) {
            vm.clearMockedCalls();
            if (i == 0) vm.mockCallRevert(address(messenger), abi.encodeWithSignature("localMinter()"), "");
            if (i == 1) {
                vm.mockCallRevert(address(minter), abi.encodeWithSelector(minter.burnLimitsPerMessage.selector), "");
            }
            if (i == 2) {
                vm.mockCall(address(messenger), abi.encodeWithSignature("localMinter()"), abi.encode(address(0xC0DE)));
            }
            minter.setLimit(5e6);
            bytes32 r = bytes32(i + 1);
            address fwd = factory.addressOf(r);
            usdc.mint(fwd, 6e6);
            vm.expectRevert("Burn amount exceeds per tx limit");
            factory.forward(r);
            assertEq(usdc.balanceOf(fwd), 6e6, "funds wait");
            assertEq(fwd.code.length, 0, "no code");

            minter.setLimit(6e6);
            factory.forward(r);
            assertEq(_last().amount, 6e6, "whole balance");
            assertEq(usdc.balanceOf(fwd), 0);
        }
    }

    /// @dev A plain call to a deposit address without code succeeds and moves
    /// nothing, so a crank service must use `instance.forward(r)` (or check
    /// for code first) and confirm by the DepositForBurn log. `addressOf` on
    /// a clone predicts clones of the clone, not deposit addresses.
    function test_directForwardOnUndeployedAddress_isNoOp() public {
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 1e6);
        (bool ok,) = fwd.call(abi.encodeWithSignature("forward()"));
        assertTrue(ok);
        assertEq(usdc.balanceOf(fwd), 1e6);
        assertEq(fwd.code.length, 0);

        factory.forward(R);
        assertTrue(Forwarder(fwd).addressOf(R) != fwd, "addressOf on a clone is not the deposit address");
    }

    /// @dev A Circle revert rolls the whole crank back, deployment included.
    function test_circleRevert_bubblesUp_fundsWait() public {
        messenger.setRemote(8, bytes32(0));
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 1e6);
        vm.expectRevert("No TokenMessenger for domain");
        factory.forward(R);
        assertEq(usdc.balanceOf(fwd), 1e6);
        assertEq(fwd.code.length, 0);
    }

    function test_crank_touchesNoStorage_inInstanceOrClone() public {
        address fwd = factory.addressOf(R);
        usdc.mint(fwd, 2e6);
        vm.record();
        factory.forward(R);
        usdc.mint(fwd, 1e6);
        Forwarder(fwd).forward();
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(factory));
        assertEq(reads.length + writes.length, 0, "instance");
        (reads, writes) = vm.accesses(fwd);
        assertEq(reads.length + writes.length, 0, "clone");
    }
}
