// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";


contract WeekManaged is Ownable {

    uint256 public offset = 4 days;
    uint256 public extra = 0;

    function getCurrentWeek() public view returns(uint256) {
        return (now + offset + extra) / (7 days);
    }

    function getNow() public view returns(uint256) {
        return now + extra;
    }

    function getUnlockWeek() public view returns(uint256) {
        return getCurrentWeek() + 2;
    }

    function getUnlockTime(uint256 time_) public view returns(uint256) {
        require(time_ + offset > (7 days), "Time not large enough");
        return ((time_ + offset) / (7 days) + 2) * (7 days) - offset;
    }

    function setOffset(uint256 offset_) external onlyOwner {
        offset = offset_;
    }

    function setExtra(uint256 extra_) external onlyOwner {
        extra = extra_;
    }
}
