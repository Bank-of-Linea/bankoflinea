import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import dotenv from 'dotenv';
import 'hardhat-contract-sizer';

dotenv.config({ path: '.env' });

const { INFURA_KEY, PRIVATE_KEY, LINEASCAN_API_KEY, BASESCAN_API_KEY } = process.env;

if (!INFURA_KEY || !PRIVATE_KEY || !LINEASCAN_API_KEY || !BASESCAN_API_KEY) {
  throw new Error(
    'INFURA_KEY, PRIVATE_KEY or LINEASCAN_API_KEY is not set in .env file',
  );
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.28',
        settings: {
          evmVersion: 'london',
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {},
    'linea-sepolia': {
      url: `https://linea-sepolia.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
    },
    'base-sepolia': {
      url: `https://base-sepolia.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
    },

    linea: {
      url: `https://linea-mainnet.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      'linea-sepolia': LINEASCAN_API_KEY,
      linea: LINEASCAN_API_KEY,
      'base-sepolia': BASESCAN_API_KEY,
    },
    customChains: [
      {
        network: 'linea-sepolia',
        chainId: 59141,
        urls: {
          apiURL: 'https://api-sepolia.lineascan.build/api',
          browserURL: 'https://sepolia.lineascan.build',
        },
      },
      {
        network: 'base-sepolia',
        chainId: 84532,
        urls: {
          apiURL: 'https://api-sepolia.basescan.org/api',
          browserURL: 'https://sepolia.basescan.org',
        },
      },
      {
        network: 'linea',
        chainId: 59144,
        urls: {
          apiURL: 'https://api.lineascan.build/api',
          browserURL: 'https://lineascan.build',
        },
      },
    ],
  },
};

export default config;
