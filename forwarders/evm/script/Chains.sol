// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Forwarder} from "../src/Forwarder.sol";

/// @notice Per-chain constants for the supported source chains and the Sui
/// destination. Circle addresses come from
/// https://developers.circle.com/cctp/references/contract-addresses and are
/// re-checked on-chain by the fork tests.
library Chains {
    struct Chain {
        string name;
        uint256 chainId;
        /// @dev `MessageTransmitterV2.localDomain()`.
        uint32 localDomain;
        /// @dev Native USDC (Circle's FiatToken, 6 decimals).
        address usdc;
        address tokenMessenger;
        address messageTransmitter;
        address tokenMinter;
        /// @dev A block after Sui (domain 8) was registered.
        uint256 forkBlock;
        string rpcEnvVar;
        string defaultRpc;
    }

    /// @dev Keyless CREATE2 deployer and the salt every instance uses.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = bytes32(0);

    uint32 internal constant SUI_DOMAIN = 8;
    /// @dev `remoteTokenMessengers(8)` on both chains' TokenMessengerV2:
    /// keccak256 of
    /// `<package>::message_transmitter_authenticator::MessageTransmitterAuthenticator`
    /// (circlefin/sui-cctp b23b83b), which Sui's MessageTransmitterV2 checks
    /// the message header's recipient against.
    bytes32 internal constant SUI_REMOTE_TOKEN_MESSENGER =
        0xf47842a2b5ac4483731927a7500175a9354d2eccd94312aa591ec50b9e8657e6;
    /// @dev Circle's mainnet `TokenMessengerMinterV2` package id on Sui
    /// (https://developers.circle.com/cctp/references/sui-packages), only used
    /// to re-derive `SUI_REMOTE_TOKEN_MESSENGER`.
    bytes32 internal constant SUI_TOKEN_MESSENGER_MINTER_V2_PACKAGE =
        0xeb14978abfe93a37c5d5bf86a0623b923553a5f0e794daac7724f1e2fdbfb830;

    function avalanche() internal pure returns (Chain memory) {
        return Chain({
            name: "avalanche",
            chainId: 43114,
            localDomain: 1,
            usdc: 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
            tokenMessenger: 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
            messageTransmitter: 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64,
            tokenMinter: 0xfd78EE919681417d192449715b2594ab58f5D002,
            forkBlock: 97000000,
            rpcEnvVar: "AVALANCHE_RPC_URL",
            defaultRpc: "https://api.avax.network/ext/bc/C/rpc"
        });
    }

    /// @dev Bridged USDC.e on Polygon is a different token and unsupported.
    function polygon() internal pure returns (Chain memory) {
        return Chain({
            name: "polygon",
            chainId: 137,
            localDomain: 7,
            usdc: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
            tokenMessenger: 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
            messageTransmitter: 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64,
            tokenMinter: 0xfd78EE919681417d192449715b2594ab58f5D002,
            forkBlock: 95150000,
            rpcEnvVar: "POLYGON_RPC_URL",
            defaultRpc: "https://polygon.drpc.org"
        });
    }

    function all() internal pure returns (Chain[2] memory) {
        return [avalanche(), polygon()];
    }

    /// @dev The instance's CREATE2 init code on `c`.
    function initCode(Chain memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Forwarder).creationCode, abi.encode(c.usdc, c.tokenMessenger, c.chainId));
    }
}
