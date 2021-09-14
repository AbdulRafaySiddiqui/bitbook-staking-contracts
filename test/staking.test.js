const { ethers, waffle } = require('hardhat')
const { expect, use } = require('chai')
const { solidity } = require('ethereum-waffle')
const { BigNumber, utils, provider } = ethers

use(solidity)
let stopSleep = false;

const sleep = async (s) => {
    stopSleep = false;
    for (let i = s; i > 0; i--) {
        process.stdout.write(`\r \\ ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r | ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r / ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r - ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        if (i === 1 || stopSleep) {
            process.stdout.clearLine();
            process.stdout.cursorTo(0);
            return;
        }
    }
}

const ZERO = new BigNumber.from('0')
const ONE = new BigNumber.from('1')
const ONE_ETH = utils.parseUnits('1000000', 5)
const LESS_ETH = utils.parseUnits('1', 5)
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const MAX_UINT = '115792089237316195423570985008687907853269984665640564039457584007913129639935'
const ONE_DAY = 86400;

let deployer, tresury, user
let staking
let token
let withdrawFee

withdrawFee = [
    { day: 1, fee: 50 },
    { day: 3, fee: 25 },
    { day: 5, fee: 15 },
    { day: 7, fee: 5 },
]

describe('Bitbook Staking', () => {
    it('It should deploy staking  and token contract', async () => {
        [deployer, tresury, user] = await ethers.getSigners()

        const tokenContract = await ethers.getContractFactory('BitBook')
        token = await tokenContract.deploy(tresury.address)

        const stakingContract = await ethers.getContractFactory('BitBookStaking')
        staking = await stakingContract.deploy(deployer.address, token.address, withdrawFee)
    })

    it("It should initialize staking", async () => {
        expect(await staking.initialized()).to.deep.equal(false);
        await staking.initialize()
        expect(await staking.initialized()).to.deep.equal(true);
    })

    it("It should deposit tokens for staking", async () => {
        await token.transfer(user.address, '10000000000')
        const balance = await token.balanceOf(user.address)
        token.connect(user).approve(staking.address, MAX_UINT);
        await expect(staking.connect(user).deposit(0, balance))
            .to.emit(staking, 'Deposit')
        const userInfo = await staking.userInfo(0, user.address)
        expect(userInfo.amount).to.deep.equal(balance);
    })

    it('It should harvest tokens', async () => {
        await staking.updatePool(0);

        await token.approve(staking.address, MAX_UINT);
        await staking.depositRewardToken(0, '108000000')
        await staking.updatePool(0);

        const poolInfo = await staking.poolInfo(0)

        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).deposit(0, 0);
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(poolInfo.tokenPerBlock)
    })

    it('It should withdraw tokens and charge 5% withdraw fee', async () => {
        await staking.connect(user).deposit(0, '100000000');
        await sleep(1)

        const userInfo = await staking.userInfo(0, user.address);

        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).withdraw(0, userInfo.amount)
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(userInfo.amount.sub(userInfo.amount.mul(50).div(1000)))
    })

    it('It should withdraw tokens and charge 2.5% withdraw fee', async () => {
        await staking.connect(user).deposit(0, '100000000');
        await sleep(2)

        const userInfo = await staking.userInfo(0, user.address);

        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).withdraw(0, userInfo.amount)
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(userInfo.amount.sub(userInfo.amount.mul(25).div(1000)))
    })

    it('It should withdraw tokens and charge 1.5% withdraw fee', async () => {
        await staking.connect(user).deposit(0, '100000000');
        await sleep(4)

        const userInfo = await staking.userInfo(0, user.address);

        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).withdraw(0, userInfo.amount)
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(userInfo.amount.sub(userInfo.amount.mul(15).div(1000)))
    })

    it('It should withdraw tokens and charge 0.5% withdraw fee', async () => {
        await staking.connect(user).deposit(0, '100000000');
        await sleep(6)

        const userInfo = await staking.userInfo(0, user.address);

        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).withdraw(0, userInfo.amount)
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(userInfo.amount.sub(userInfo.amount.mul(5).div(1000)))
    })

    it('It should withdraw tokens and not charge withdraw fee', async () => {
        await staking.connect(user).deposit(0, '100000000');
        await sleep(8)
        
        const userInfo = await staking.userInfo(0, user.address);
        const balanceBefore = await token.balanceOf(user.address);
        await staking.connect(user).withdraw(0, userInfo.amount)
        const balanceAfter = await token.balanceOf(user.address);

        expect(balanceAfter.sub(balanceBefore)).to.deep.equal(userInfo.amount)
    })
})