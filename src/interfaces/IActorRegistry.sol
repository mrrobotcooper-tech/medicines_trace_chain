// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum ActorType {
    None,
    Manufacturer,
    Distributor,
    Pharmacy
}

interface IActorRegistry {
    /// @return El tipo de actor SOLO si su licencia esta vigente y no esta suspendido; si no, None.
    function activeTypeOf(address account) external view returns (ActorType);

    function isRegulator(address account) external view returns (bool);
}
