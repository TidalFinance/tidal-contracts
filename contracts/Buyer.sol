// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/ISeller.sol";
import "./interfaces/IPolicy.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // The base of premium rate and accWeeklyCost
    uint256 constant PREMIUM_BASE = 1e6;

    IERC20 public baseToken;  // By default it's USDC
    IAssetManager public assetManager;
    ISeller public seller;

    struct UserInfo {
        uint256 balance;
        uint256 weekBegin;  // The week the coverage begin
        uint256 weekEnd;  // The week the coverage end
        uint256 weekUpdated;  // The week that balance was updated
    }

    mapping(address => UserInfo) public userInfoMap;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override currentSubscription;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override futureSubscription;

    // week => assetIndex => total
    mapping(uint256 => mapping(uint256 => uint256)) public weeklyTotalSubscription;

    constructor (IERC20 baseToken_, IAssetManager assetManager_) public {
        baseToken = baseToken_;
        assetManager = assetManager_;
    }

    function setBaseToken(IERC20 baseToken_) public onlyOwner {
        baseToken = baseToken_;
    }

    function setAssetManager(IAssetManager assetManager_) public onlyOwner {
        assetManager = assetManager_;
    }

    function setSeller(ISeller seller_) public onlyOwner {
        seller = seller_;
    }

    function getPremiumRate(uint8 category_, uint256 week_) public view returns(uint256) {
        if (category_ == 0) {
            return 14000;
        } else if (category_ == 1) {
            return 56000;
        } else {
            return 108000;
        }
    }

    function getCurrentWeek() public view returns(uint256) {
        return now.div(7 days);
    }

    function isUserCovered(address who_) public override view returns(bool) {
        return userInfoMap[who_].weekEnd == getCurrentWeek();
    }

    function getTotalFutureSubscription(address who_) public view returns(uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < assetManager.getAssetLength(); ++i) {
            if (futureSubscription[who_][i] > 0) {
                total = total.add(futureSubscription[who_][i]);
            }
        }

        return total;
    }

    function getBalance(address who_) public view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    // Called for every user every week.
    function update(address who_) public {
        uint256 currentWeek = getCurrentWeek();
        uint256 cost = getTotalFutureSubscription(who_);

        if (userInfoMap[who_].balance >= cost) {
            userInfoMap[who_].balance = userInfoMap[who_].balance.sub(cost);

            if (userInfoMap[who_].weekBegin == 0 ||
                    userInfoMap[who_].weekEnd < userInfoMap[who_].weekUpdated) {
                userInfoMap[who_].weekBegin = currentWeek;
            }

            userInfoMap[who_].weekEnd = currentWeek;

            for (uint256 i = 0; i < assetManager.getAssetLength(); ++i) {
                if (futureSubscription[who_][i] > 0) {
                    currentSubscription[who_][i] = futureSubscription[who_][i];
                    weeklyTotalSubscription[currentWeek][i] =
                        weeklyTotalSubscription[currentWeek][i].add(futureSubscription[who_][i]);
                } else if (currentSubscription[who_][i] > 0) {
                    currentSubscription[who_][i] = 0;
                }
            }
        }
        
        userInfoMap[who_].weekUpdated = currentWeek;  // This week.
    }

    // Deposit
    function deposit(uint256 amount_) external {
        update(msg.sender);

        baseToken.safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external {
        update(msg.sender);

        require(userInfoMap[msg.sender].balance > amount_, "not enough balance");
        baseToken.safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].add(amount_);
    }

    function unsubscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].sub(amount_);
    }
}
