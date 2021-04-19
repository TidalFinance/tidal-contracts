// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./WeekManaged.sol";

// This contract is owned by Timelock.
contract Staking is Ownable, WeekManaged {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // For improving precision of premiumPerShare and bonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IERC20 public tidalToken;

    struct WithdrawRequest {
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => week => WithdrawRequest
    mapping(address => mapping(uint256 => WithdrawRequest)) public withdrawRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 premiumPerShare;
        uint256 bonusPerShare;
    }

    PoolInfo public poolInfo;

    struct UserBalance {
        uint256 currentBalance;
        uint256 futureBalance;
    }

    mapping(address => UserBalance) public userBalance;

    struct UserInfo {
        uint256 week;
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfo;

    // Balance here not withdrawn yet, and are good for staking bonus.
    uint256 public assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // payoutId => PayoutInfo
    mapping(uint256 => PayoutInfo) public payoutInfo;

    uint256 public payoutId;

    // who => payoutId
    mapping(address => uint256) userPayoutIdMap;

    constructor () public { }

    function setTidalToken(IERC20 tidalToken_) external onlyOwner {
        tidalToken = tidalToken_;
    }

    // Update and pay last week's bonus. Admin should call
    function updateBonus(uint256 amount_) external onlyOwner {
        uint256 week = getCurrentWeek();

        require(poolInfo.weekOfBonus < week, "already updated");

        if (assetBalance > 0) {
            IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo.bonusPerShare =
                amount_.mul(UNIT_PER_SHARE).div(assetBalance);
        }

        poolInfo.weekOfBonus = week;
    }

    // Called for every user every week.
    function update(address who_) external {
        uint256 week = getCurrentWeek();

        require(userInfo[who_].week < week, "Already updated");

        // Assert if bonus not updated, or user already updated.
        require(poolInfo.weekOfBonus == week, "Not ready");

        uint256 currentBalance = userBalance[who_].currentBalance;
        uint256 futureBalance = userBalance[who_].futureBalance;

        // Update bonus.
        userInfo[who_].bonus = userInfo[who_].bonus.add(currentBalance.mul(
            poolInfo.bonusPerShare).div(UNIT_PER_SHARE));

        // Update balances and baskets if no claims.
        if (!isAssetLocked(who_)) {
            assetBalance = assetBalance.add(futureBalance).sub(currentBalance);
            userBalance[who_].currentBalance = futureBalance;
        }

        // Update week.
        userInfo[who_].week = week;
    }

    function isAssetLocked(address who_) public view returns(bool) {
        return payoutId > 0 && !payoutInfo[payoutId].finished && userPayoutIdMap[who_] < payoutId;
    }

    function hasPendingPayout() public view returns(bool) {
        return payoutId > 0 && !payoutInfo[payoutId].finished;
    }

    function deposit(uint256 amount_) external {
        require(!hasPendingPayout(), "Has pending payout");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        tidalToken.safeTransferFrom(msg.sender, address(this), amount_);
        userBalance[msg.sender].futureBalance = userBalance[msg.sender].futureBalance.add(amount_);
    }

    function reduceDeposit(uint256 amount_) external {
        // Even asset locked, user can still reduce.

        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");
        require(amount_ <= userBalance[msg.sender].futureBalance.sub(
            userBalance[msg.sender].currentBalance), "Not enough future balance");

        tidalToken.safeTransfer(msg.sender, amount_);
        userBalance[msg.sender].futureBalance = userBalance[msg.sender].futureBalance.sub(amount_);
    }

    function withdraw(uint256 amount_) external {
        require(!hasPendingPayout(), "Has pending payout");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender].currentBalance, "Not enough user balance");

        WithdrawRequest memory request;
        request.amount = amount_;
        request.time = getNow();
        request.executed = false;
        withdrawRequestMap[msg.sender][getUnlockWeek()] = request;
    }

    function withdrawReady(address who_) external {
        WithdrawRequest storage request = withdrawRequestMap[msg.sender][getCurrentWeek()];

        require(!hasPendingPayout(), "Has pending payout");
        require(userInfo[who_].week == getCurrentWeek(), "Not updated yet");
        require(!request.executed, "already executed");
        require(request.time > 0, "No request");

        uint256 unlockTime = getUnlockTime(request.time);
        require(getNow() > unlockTime, "Not ready to withdraw yet");

        tidalToken.safeTransfer(msg.sender, request.amount);

        assetBalance = assetBalance.sub(request.amount);
        userBalance[who_].currentBalance = userBalance[who_].currentBalance.sub(request.amount);
        userBalance[who_].futureBalance = userBalance[who_].futureBalance.sub(request.amount);

        request.executed = true;
    }

    function claimBonus() external {
        tidalToken.safeTransfer(msg.sender, userInfo[msg.sender].bonus);
        userInfo[msg.sender].bonus = 0;
    }

    function startPayout(uint256 payoutId_) external onlyOwner {
        require(payoutId_ == payoutId + 1, "payoutId should be increasing");
        payoutId = payoutId_;
    }

    function setPayout(uint256 payoutId_, address toAddress_, uint256 total_) external onlyOwner {
        require(payoutId_ == payoutId, "payoutId should be started");
        require(payoutInfo[payoutId_].total == 0, "already set");
        require(total_ <= assetBalance, "More than asset");

        payoutInfo[payoutId_].toAddress = toAddress_;
        payoutInfo[payoutId_].total = total_;
        payoutInfo[payoutId_].unitPerShare = total_.mul(UNIT_PER_SHARE).div(assetBalance);
        payoutInfo[payoutId_].paid = 0;
        payoutInfo[payoutId_].finished = false;
    }

    function doPayout(address who_) external {
        for (uint256 payoutId_ = userPayoutIdMap[who_] + 1; payoutId_ <= payoutId; ++payoutId_) {
            userPayoutIdMap[who_] = payoutId_;

            if (payoutInfo[payoutId_].finished) {
                continue;
            }

            uint256 amountToPay = userBalance[who_].currentBalance.mul(payoutInfo[payoutId_].unitPerShare).div(UNIT_PER_SHARE);

            userBalance[who_].currentBalance = userBalance[who_].currentBalance.sub(amountToPay);
            userBalance[who_].futureBalance = userBalance[who_].futureBalance.sub(amountToPay);
            assetBalance = assetBalance.sub(amountToPay);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].paid.add(amountToPay);
        }
    }

    function finishPayout(uint256 payoutId_) external {
        require(!payoutInfo[payoutId_].finished, "already finished");

        if (payoutInfo[payoutId_].paid < payoutInfo[payoutId_].total) {
            // In case there is still small error.
            tidalToken.safeTransferFrom(msg.sender, address(this), payoutInfo[payoutId_].total - payoutInfo[payoutId_].paid);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].total;
        }

        tidalToken.safeTransfer(payoutInfo[payoutId_].toAddress, payoutInfo[payoutId_].total);

        payoutInfo[payoutId_].finished = true;
    }
}
