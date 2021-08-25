// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/IMigratable.sol";

contract Migratable is IMigratable {

    IMigratable public migrateTo;

    function approveMigration(IMigratable migrateTo_) external override {
        require(address(migrateTo_) != address(0) &&
                address(migrateTo_) != address(this), "Invalid migrateTo_");
        migrateTo = migrateTo_;
    }

    function onMigration(address who_, uint256 amount_, bytes memory data_) external virtual override {
    }
}
