// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

abstract contract WeekManaged {

    uint256 public offset = 4 days;

    function getCurrentWeek() public view returns(uint256) {
        return (now + offset) / (7 days);
    }

    function getNow() public view returns(uint256) {
        return now;
    }

    function getUnlockWeek() public view returns(uint256) {
        return getCurrentWeek() + 2;
    }

    function getUnlockTime(uint256 time_) public view returns(uint256) {
        require(time_ + offset > (7 days), "Time not large enough");
        return ((time_ + offset) / (7 days) + 2) * (7 days) - offset;
    }
}
