// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IBuyer {
    function currentSubscription(address who_, uint256 assetIndex_) external view returns(uint256);
    function futureSubscription(address who_, uint256 assetIndex_) external view returns(uint256);
    function isUserCovered(address who_) external view returns(bool);
}
