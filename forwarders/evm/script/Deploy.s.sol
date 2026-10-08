// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Forwarder} from "../src/Forwarder.sol";
import {Chains} from "./Chains.sol";

/// @notice Deploys the instance through the keyless CREATE2 deployer with salt
/// 0, the only way it is ever deployed. Refuses unless the current build lands
/// at the instance in `fixtures/address-vectors.json`, the address users'
/// deposit addresses derive from, so a changed source, compiler setting or
/// dependency cannot create a second set of deposit addresses. Does nothing
/// where the instance already has code.
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract Deploy is Script {
    using stdJson for string;

    function run() external returns (Forwarder instance) {
        string memory json = vm.readFile("fixtures/address-vectors.json");
        address pinned = json.readAddress(".instance");
        require(Chains.instance() == pinned, "build does not land at the pinned instance");
        require(Chains.CREATE2_DEPLOYER.code.length > 0, "no keyless deployer on this chain");
        instance = Forwarder(pinned);
        console2.log("chain", block.chainid);
        console2.log("instance", pinned);
        if (pinned.code.length > 0) {
            console2.log("already deployed");
            return instance;
        }

        vm.startBroadcast();
        (bool ok,) = Chains.CREATE2_DEPLOYER.call(abi.encodePacked(Chains.SALT, Chains.initCode()));
        vm.stopBroadcast();
        require(ok && pinned.code.length > 0, "deployment failed: Circle checks or deployer");
        require(
            instance.addressOf(json.readBytes32(".vectors[0].recipient")) == json.readAddress(".vectors[0].address"),
            "deposit address differs from the fixture"
        );
    }
}
