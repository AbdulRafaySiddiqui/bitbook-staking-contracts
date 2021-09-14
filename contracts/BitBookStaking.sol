// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import './IBEP20Mintable.sol';
import './IBEP20.sol';
import './SafeBEP20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

contract Reserve is Ownable {
    function safeTransfer(
        IBEP20 rewardToken,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        uint256 tokenBal = rewardToken.balanceOf(address(this));
        if (_amount > tokenBal) {
            rewardToken.transfer(_to, tokenBal);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }
}

contract BitBookStaking is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct WithdrawFeeInterval {
        uint256 day;
        uint256 fee;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 rewardLockedUp;
        uint256 nextHarvestUntil;
        uint256 depositTimestamp;
    }

    struct PoolInfo {
        IBEP20 stakedToken;
        IBEP20 rewardToken;
        uint256 stakedAmount;
        uint256 rewardSupply;
        uint256 tokenPerBlock;
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
        uint16 depositFeeBP;
        uint256 minDeposit;
        uint256 harvestInterval;
        bool lockDeposit;
    }

    Reserve public rewardReserve;
    uint256 public constant BONUS_MULTIPLIER = 1;
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    mapping(address => mapping(address => bool)) poolExists;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => WithdrawFeeInterval[]) public withdrawFee;
    uint256 public startBlock;
    bool public paused = true;
    bool public initialized = false;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        address _owner,
        IBEP20 token,
        WithdrawFeeInterval[] memory _withdrawFee
    ) public {
        startBlock = 0;
        rewardReserve = new Reserve();
        transferOwnership(_owner);
        // WithdrawFeeInterval[] memory _withdrawFee = new WithdrawFeeInterval[](5);
        // _withdrawFee[0] = WithdrawFeeInterval(3 days, 50);
        // _withdrawFee[1] = WithdrawFeeInterval(10 days, 25);
        // _withdrawFee[2] = WithdrawFeeInterval(30 days, 15);
        // _withdrawFee[3] = WithdrawFeeInterval(90 days, 5);
        add(108e6, token, token, 0, 0, 0, _withdrawFee);
    }

    function initialize() public onlyOwner {
        require(!initialized, 'BITBOOK_STAKING: Staking already started!');
        initialized = true;
        paused = false;
        startBlock = block.number;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            poolInfo[pid].lastRewardBlock = startBlock;
        }
    }

    function getWithdrawFeeIntervals(uint256 poolId) external view returns (WithdrawFeeInterval[] memory) {
        return withdrawFee[poolId];
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(
        uint256 _tokenPerBlock,
        IBEP20 _stakedToken,
        IBEP20 _rewardToken,
        uint16 _depositFeeBP,
        uint256 _minDeposit,
        uint256 _harvestInterval,
        WithdrawFeeInterval[] memory withdrawFeeIntervals
    ) public onlyOwner {
        require(poolInfo.length <= 1000, 'BITBOOK_STAKING: Pool Length Full!');
        require(!poolExists[address(_stakedToken)][address(_rewardToken)], 'BITBOOK_STAKING: Pool Already Exists!');
        require(_depositFeeBP <= 10000, 'BITBOOK_STAKING: invalid deposit fee basis points');
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, 'BITBOOK_STAKING: invalid harvest interval');

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(
            PoolInfo({
                stakedToken: _stakedToken,
                rewardToken: _rewardToken,
                stakedAmount: 0,
                rewardSupply: 0,
                tokenPerBlock: _tokenPerBlock,
                lastRewardBlock: lastRewardBlock,
                accTokenPerShare: 0,
                depositFeeBP: _depositFeeBP,
                minDeposit: _minDeposit,
                harvestInterval: _harvestInterval,
                lockDeposit: false
            })
        );
        for (uint256 i = 0; i < withdrawFeeIntervals.length; i++) {
            withdrawFee[poolInfo.length - 1].push(withdrawFeeIntervals[i]);
        }
        poolExists[address(_stakedToken)][address(_rewardToken)] = true;
    }

    function set(
        uint256 _pid,
        uint256 _tokenPerBlock,
        uint16 _depositFeeBP,
        uint256 _minDeposit,
        uint256 _harvestInterval
    ) public onlyOwner {
        require(_depositFeeBP <= 10000, 'BITBOOK_STAKING: invalid deposit fee basis points');
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, 'BITBOOK_STAKING: invalid harvest interval');

        poolInfo[_pid].tokenPerBlock = _tokenPerBlock;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].minDeposit = _minDeposit;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        if (
            block.number > pool.lastRewardBlock &&
            pool.stakedAmount != 0 &&
            pool.rewardToken.balanceOf(address(this)) > 0
        ) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(pool.tokenPerBlock);
            accTokenPerShare = accTokenPerShare.add(tokenReward.mul(1e12).div(pool.stakedAmount));
        }
        return user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 tokenBalance = pool.stakedAmount;
        if (tokenBalance == 0 || pool.tokenPerBlock == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(pool.tokenPerBlock);
        uint256 rewardTokenSupply = pool.rewardSupply;
        uint256 reward = tokenReward > rewardTokenSupply ? rewardTokenSupply : tokenReward;
        if (reward > 0) {
            pool.rewardSupply -= reward;
            pool.accTokenPerShare = pool.accTokenPerShare.add(reward.mul(1e12).div(tokenBalance));
        }
        pool.lastRewardBlock = block.number;
    }

    function depositRewardToken(uint256 poolId, uint256 amount) external {
        PoolInfo storage _poolInfo = poolInfo[poolId];
        uint256 initialBalance = _poolInfo.rewardToken.balanceOf(address(rewardReserve));
        _poolInfo.rewardToken.safeTransferFrom(msg.sender, address(rewardReserve), amount);
        uint256 finalBalance = _poolInfo.rewardToken.balanceOf(address(rewardReserve));
        _poolInfo.rewardSupply += finalBalance.sub(initialBalance);
    }

    function deposit(uint256 _pid, uint256 _amount) public {
        require(paused == false, 'BITBOOK_STAKING: Paused!');
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.lockDeposit, 'BITBOOK_STAKING: Deposit Locked!');
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingToken(_pid);
        if (_amount > 0) {
            require(_amount >= poolInfo[_pid].minDeposit, 'BITBOOK_STAKING: Not Enough Required Staking Tokens!');
            user.depositTimestamp = block.timestamp;
            uint256 initialBalance = pool.stakedToken.balanceOf(address(this));
            pool.stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            uint256 finalBalance = pool.stakedToken.balanceOf(address(this));
            uint256 delta = finalBalance.sub(initialBalance);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.stakedToken.safeTransfer(owner(), depositFee);
                user.amount = user.amount.add(delta).sub(depositFee);
                pool.stakedAmount = pool.stakedAmount.add(delta).sub(depositFee);
            } else {
                user.amount = user.amount.add(delta);
                pool.stakedAmount = pool.stakedAmount.add(delta);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, 'BITBOOK_STAKING: withdraw not good');
        updatePool(_pid);
        payOrLockupPendingToken(_pid);
        uint256 amountToTransfer = _amount;
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uint256 _withdrawFee = getWithdrawFee(_pid, user.depositTimestamp);
            uint256 feeAmount = _amount.mul(_withdrawFee).div(1000);
            amountToTransfer = _amount.sub(feeAmount);
            pool.stakedAmount = pool.stakedAmount.sub(_amount);
            pool.stakedToken.safeTransfer(owner(), feeAmount);
            pool.stakedToken.safeTransfer(address(msg.sender), amountToTransfer);
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, amountToTransfer);
    }

    function payOrLockupPendingToken(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                rewardReserve.safeTransfer(pool.rewardToken, msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    function getWithdrawFee(uint256 poolId, uint256 stakedTime) public view returns (uint256) {
        uint256 depositTime = block.timestamp.sub(stakedTime);
        WithdrawFeeInterval[] storage _withdrawFee = withdrawFee[poolId];
        for (uint256 i = 0; i < _withdrawFee.length; i++) {
            if (depositTime <= _withdrawFee[i].day) return _withdrawFee[i].fee;
        }
        return 0;
    }

    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.stakedToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function emergencyAdminWithdraw(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.rewardToken.transfer(owner(), pool.rewardToken.balanceOf(address(this)));
        rewardReserve.safeTransfer(pool.rewardToken, owner(), pool.rewardToken.balanceOf(address(rewardReserve)));
        pool.accTokenPerShare = 0;
        pool.tokenPerBlock = 0;
        pool.lastRewardBlock = block.number;
    }

    function updatePaused(bool _value) public onlyOwner {
        paused = _value;
    }

    function setLockDeposit(uint256 pid, bool locked) public onlyOwner {
        poolInfo[pid].lockDeposit = locked;
    }
}
