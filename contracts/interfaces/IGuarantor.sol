// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./IMigratable.sol";

interface IGuarantor is IMigratable {
    function updateBonus(uint16 assetIndex_, uint256 amount_) external;
    function update(address who_) external;
    function startPayout(uint16 assetIndex_, uint256 payoutId_) external;
    function setPayout(uint16 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external;
}
