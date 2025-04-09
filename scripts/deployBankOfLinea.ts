import { ethers, run } from 'hardhat';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

async function main() {
  console.log('Deploying BankOfLinea...');

  const marketingWallet = process.env.MARKETING_WALLET;

  if (!marketingWallet) {
    throw new Error('MARKETING_WALLET is not set in .env file');
  }

  const bankOfLinea = await ethers.deployContract('BankOfLinea', [
    marketingWallet,
  ]);
  await bankOfLinea.waitForDeployment();
  const bankOfLineaAddress = await bankOfLinea.getAddress();

  await new Promise((resolve) => setTimeout(resolve, 3000));

  await run('verify:verify', {
    address: bankOfLineaAddress,
    constructorArguments: [marketingWallet],
  });

  console.log(`BankOfLinea successfully deployed and verified!`);
  console.log(`BankOfLinea is at ${bankOfLineaAddress}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
