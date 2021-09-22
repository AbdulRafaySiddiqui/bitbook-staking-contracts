const { ethers } = require('hardhat')
const hre = require('hardhat')

const sleep = async (s) => {
    for (let i = s; i > 0; i--) {
        process.stdout.write(`\r \\ ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r | ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r / ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        process.stdout.write(`\r - ${i} waiting..`)
        await new Promise(resolve => setTimeout(resolve, 250));
        if (i === 1) {
            process.stdout.clearLine();
            process.stdout.cursorTo(0);
            return;
        }
    }
}

const ROUTERS = {
    PANCAKE: '0x10ED43C718714eb63d5aA57B78B54704E256024E',
    PANCAKE_TESTNET: '0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3',
    UNISWAP: '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D',
    SUSHISWAP_TESTNET: '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506',
}

async function main() {
    const [deployer] = await ethers.getSigners()

    const bitbookContract = await ethers.getContractFactory('BitBook');
    const bitbook = await bitbookContract.deploy(deployer.address)
    console.log('BitBook Token', bitbook.address)

    const withdrawFee = [
        { day: 600, fee: 50 },
        { day: 1200, fee: 25 },
        { day: 2400, fee: 15 },
        { day: 3600, fee: 5 },
    ]
    const stakingContract = await ethers.getContractFactory('BitBookStaking')
    const staking = await stakingContract.deploy(deployer.address, bitbook.address, withdrawFee)
    console.log('Staking', staking.address)

    await sleep(10) 

    await hre.run('verify:verify', {
        address: bitbook.address,
        constructorArguments: [deployer.address],
    })

    await hre.run('verify:verify', {
        address: staking.address,
        constructorArguments: [deployer.address, bitbook.address, withdrawFee],
    })
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })

