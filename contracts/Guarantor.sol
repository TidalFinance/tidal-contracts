// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";


// This contract is owned by Timelock.
contract Guarantor is IGuarantor, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // For improving precision of accPremiumPerShare and accBonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IBuyer public buyer;
    IAssetManager public assetManager;
    IERC20 public baseToken;  // By default it's USDC
    IERC20 public tidalToken;

    struct WithdrawRequest {
        uint256 assetIndex;
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => WithdrawRequest[]
    mapping(address => WithdrawRequest[]) public withdrawRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(uint256 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 week;
        uint256 balance;
        uint256 premium;
        uint256 bonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(address => mapping(uint256 => UserInfo)) public userInfo;

    // Balance here not withdrawn yet, and are good for staking bonus.
    // assetIndex => amount
    mapping(uint256 => uint256) public assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // payoutId => PayoutInfo
    mapping(uint256 => PayoutInfo) public payoutInfo;

    // assetIndex => payoutId
    mapping(uint256 => uint256) public payoutIdMap;

    // who => assetIndex => payoutId
    mapping(address => mapping(uint256 => uint256)) userPayoutIdMap;

    constructor (IBuyer buyer_, IAssetManager assetManager_, IERC20 baseToken_, IERC20 tidalToken_) public {
        buyer = buyer_;
        assetManager = assetManager_;
        baseToken = baseToken_;
        tidalToken = tidalToken_;
    }

    function getWeekByTime(uint256 time_) public pure returns(uint256) {
        return time_ / (7 days);
    }

    function getWithdrawTime(uint256 time_) public pure returns(uint256) {
        return (time_ / (7 days) + 2) * (7 days);
    }

    // Update and pay last week's premium.
    function updatePremium(uint256 assetIndex_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount_);
        poolInfo[assetIndex_].accPremiumPerShare = poolInfo[assetIndex_].accPremiumPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]));

        poolInfo[assetIndex_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint256 assetIndex_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
        poolInfo[assetIndex_].accBonusPerShare = poolInfo[assetIndex_].accBonusPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]));

        poolInfo[assetIndex_].weekOfBonus = week;
    }

    // Update user's last week's premium and bonus.
    function _updateUserPremiumAndBonus(address who_, uint256 assetIndex_) private {
        uint256 week = getWeekByTime(now).sub(1);

        // Return if premium or bonus not updated, or user already updated.
        if (userInfo[who_][assetIndex_].week > poolInfo[assetIndex_].weekOfPremium ||
                userInfo[who_][assetIndex_].week > poolInfo[assetIndex_].weekOfBonus ||
                userInfo[who_][assetIndex_].week >= week) {
            return;
        }

        uint256 userBalance = userInfo[who_][assetIndex_].balance;

        // Update premium.
        userInfo[who_][assetIndex_].premium = userInfo[who_][assetIndex_].premium.add(userBalance.mul(
            poolInfo[assetIndex_].accPremiumPerShare.sub(userInfo[who_][assetIndex_].accPremiumPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][assetIndex_].accPremiumPerShare = poolInfo[assetIndex_].accPremiumPerShare;

        // Update bonus.
        userInfo[who_][assetIndex_].bonus = userInfo[who_][assetIndex_].bonus.add(userBalance.mul(
            poolInfo[assetIndex_].accBonusPerShare.sub(userInfo[who_][assetIndex_].accBonusPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][assetIndex_].accBonusPerShare = poolInfo[assetIndex_].accBonusPerShare;

        // Update week.
        userInfo[who_][assetIndex_].week = week;
    }

    function isAssetLocked(address who_, uint256 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[payoutId].finished && userPayoutIdMap[who_][assetIndex_] < payoutId;
    }

    function hasPendingPayout(uint256 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[payoutId].finished;
    }

    function deposit(uint256 assetIndex_, uint256 amount_) external {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");

        _updateUserPremiumAndBonus(msg.sender, assetIndex_);

        address token = assetManager.getAssetToken(assetIndex_);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount_);

        assetBalance[assetIndex_] = assetBalance[assetIndex_].add(amount_);

        userInfo[msg.sender][assetIndex_].balance = userInfo[msg.sender][assetIndex_].balance.add(amount_);
    }

    function withdraw(uint256 assetIndex_, uint256 amount_) external {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userInfo[msg.sender][assetIndex_].balance, "Not enough user balance");

        _updateUserPremiumAndBonus(msg.sender, assetIndex_);

        WithdrawRequest memory request;
        request.assetIndex = assetIndex_;
        request.amount = amount_;
        request.time = now;
        request.executed = false;
        withdrawRequestMap[msg.sender].push(request);
    }

    function withdrawReady(address who_, uint256 requestIndex_) external {
        WithdrawRequest storage request = withdrawRequestMap[msg.sender][requestIndex_];

        require(!hasPendingPayout(request.assetIndex), "Has pending payout");
        require(!request.executed, "already executed");

        uint256 unlockTime = getWithdrawTime(request.time);

        require(now > unlockTime, "Not ready to withdraw yet");

        address token = assetManager.getAssetToken(request.assetIndex);
        IERC20(token).safeTransfer(msg.sender, request.amount);

        assetBalance[request.assetIndex] = assetBalance[request.assetIndex].sub(request.amount);
        userInfo[who_][request.assetIndex].balance = userInfo[who_][request.assetIndex].balance.sub(request.amount);

        request.executed = true;
    }

    function claimPremium(uint256 assetIndex_) external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender][assetIndex_].premium);
        userInfo[msg.sender][assetIndex_].premium = 0;
    }

    function claimBonus(uint256 assetIndex_) external {
        IERC20(tidalToken).safeTransfer(msg.sender, userInfo[msg.sender][assetIndex_].bonus);
        userInfo[msg.sender][assetIndex_].bonus = 0;
    }

    function startPayout(uint256 assetIndex_, uint256 payoutId_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_] + 1, "payoutId should be increasing");
        payoutIdMap[assetIndex_] = payoutId_;
    }

    function setPayout(uint256 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_], "payoutId should be started");
        require(payoutInfo[payoutId_].total == 0, "already set");
        require(total_ <= assetBalance[assetIndex_], "More than asset");

        payoutInfo[payoutId_].toAddress = toAddress_;
        payoutInfo[payoutId_].total = total_;
        payoutInfo[payoutId_].unitPerShare = total_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]);
        payoutInfo[payoutId_].paid = 0;
        payoutInfo[payoutId_].finished = false;
    }

    function doPayout(address who_, uint256 assetIndex_) external {
        for (uint256 payoutId = userPayoutIdMap[who_][assetIndex_] + 1; payoutId <= payoutIdMap[assetIndex_]; ++payoutId) {
            userPayoutIdMap[who_][assetIndex_] = payoutId;

            if (payoutInfo[payoutId].finished) {
                continue;
            }

            uint256 amountToPay = userInfo[who_][assetIndex_].balance.mul(payoutInfo[payoutId].unitPerShare).div(UNIT_PER_SHARE);

            userInfo[who_][assetIndex_].balance = userInfo[who_][assetIndex_].balance.sub(amountToPay);
            assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amountToPay);
            payoutInfo[payoutId].paid = payoutInfo[payoutId].paid.add(amountToPay);
        }
    }

    function finishPayout(uint256 payoutId_) external {
        require(!payoutInfo[payoutId_].finished, "already finished");

        if (payoutInfo[payoutId_].paid < payoutInfo[payoutId_].total) {
            // In case there is still small error.
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), payoutInfo[payoutId_].total - payoutInfo[payoutId_].paid);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].total;
        }

        IERC20(tidalToken).safeTransfer(payoutInfo[payoutId_].toAddress, payoutInfo[payoutId_].total);

        payoutInfo[payoutId_].finished = true;
    }
}
