// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IBuyer {
    function findWeekCovered(address who_) external view returns(uint256, uint256);
    function currentCoveredAmount(address who_, uint256 assetIndex_) external view returns(uint256);
}
