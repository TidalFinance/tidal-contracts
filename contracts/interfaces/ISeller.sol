// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./IMigratable.sol";

interface ISeller is IMigratable {
    function assetBalance(uint16 assetIndex_) external view returns(uint256);
    function updateBonus(uint16 assetIndex_, uint256 amount_) external;
    function update(address who_) external;
    function isAssetLocked(uint16 assetIndex_) external view returns(bool);
    function startPayout(uint16 assetIndex_, uint256 payoutId_) external;
    function setPayout(uint16 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external;
}
