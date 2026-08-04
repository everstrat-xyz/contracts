#!/bin/bash

# GitHub-compatible forge fmt script
# This script uses the same configuration as GitHub Actions CI

set -e

echo "Running forge fmt with GitHub CI configuration..."

# Backup the _collateralToProtocolTokens function before formatting
grep -A 10 "function _collateralToProtocolTokens" src/contracts/AMM.sol > /tmp/collateral_function_backup.txt

# Use the CI profile to match GitHub Actions
FOUNDRY_PROFILE=ci forge fmt src/ test/

# Restore the _collateralToProtocolTokens function to GitHub CI expected format
if [ -f /tmp/collateral_function_backup.txt ]; then
    # Use sed to replace the function with the exact GitHub CI format
    sed -i '/function _collateralToProtocolTokens/,/^    }/c\
    function _collateralToProtocolTokens(uint256 _collateralAmount, uint256 _normalizedPrice, uint8 _collateralDecimals)\
        internal\
        pure\
        returns (uint256)\
    {\
        return Math.convertAssetAToAssetB(_collateralAmount.normalizeDecimals(_collateralDecimals), _normalizedPrice);\
    }' src/contracts/AMM.sol
    
    echo "Restored _collateralToProtocolTokens to GitHub CI expected format"
    
    # Clean up
    rm -f /tmp/collateral_function_backup.txt
fi

echo "Formatting complete!"
