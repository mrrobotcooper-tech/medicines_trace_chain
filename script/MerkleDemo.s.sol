// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @notice Calcula (sin enviar transacciones) la raiz Merkle y las pruebas de 4 series de ejemplo,
///         con exactamente la misma regla que usa MedicineRegistry.
contract MerkleDemo is Script {
    function run() external pure {
        bytes32[4] memory serial;
        bytes32[4] memory leaf;
        string[4] memory names = ["SN-0001", "SN-0002", "SN-0003", "SN-0004"];
        for (uint256 i = 0; i < 4; i++) {
            serial[i] = keccak256(bytes(names[i]));
            leaf[i] = keccak256(abi.encodePacked(serial[i]));
        }
        bytes32 n01 = _pair(leaf[0], leaf[1]);
        bytes32 n23 = _pair(leaf[2], leaf[3]);
        bytes32 root = _pair(n01, n23);

        console.log("ROOT (serialsRoot):", vm.toString(root));
        console.log("serial SN-0001    :", vm.toString(serial[0]));
        console.log("proof[0] SN-0001  :", vm.toString(leaf[1]));
        console.log("proof[1] SN-0001  :", vm.toString(n23));
        console.log("serial SN-0002    :", vm.toString(serial[1]));
        console.log("proof[0] SN-0002  :", vm.toString(leaf[0]));
        console.log("proof[1] SN-0002  :", vm.toString(n23));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
