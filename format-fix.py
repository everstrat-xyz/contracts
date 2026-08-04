#!/usr/bin/env python3

import re
import sys

def fix_collateral_function(content):
    """Fix the _collateralToProtocolTokens function to match GitHub CI format"""
    
    # Pattern to match the function with any formatting
    pattern = r'(\s*)function _collateralToProtocolTokens\([^)]*\)\s*internal\s*pure\s*returns\s*\([^)]*\)\s*\{'
    
    # Find the function
    match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
    if not match:
        return content
    
    # Extract the indentation
    indent = match.group(1)
    
    # Replace with the GitHub CI expected format
    replacement = f"""{indent}function _collateralToProtocolTokens(uint256 _collateralAmount, uint256 _normalizedPrice, uint8 _collateralDecimals)
{indent}    internal
{indent}    pure
{indent}    returns (uint256)
{indent}{{"""
    
    # Replace the function signature
    content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)
    
    return content

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 format-fix.py <file>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    
    try:
        with open(file_path, 'r') as f:
            content = f.read()
        
        # Fix the function
        fixed_content = fix_collateral_function(content)
        
        with open(file_path, 'w') as f:
            f.write(fixed_content)
        
        print(f"Fixed _collateralToProtocolTokens function in {file_path}")
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
