import { SimpleArchitectureChecker } from '../simple-architecture-checker';

describe('Contract Detection', () => {
  let checker: SimpleArchitectureChecker;

  beforeEach(() => {
    process.env.GITHUB_TOKEN = 'test-token';
    process.env.GITHUB_REPO = 'test/repo';
    
    // Mock the constructor to avoid file system calls
    jest.spyOn(SimpleArchitectureChecker.prototype as any, 'loadMermaidComponents').mockImplementation(() => {});
    
    checker = new SimpleArchitectureChecker('test-token', 'test/repo');
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  describe('getContractName', () => {
    it('should extract contract name from src/ directory', () => {
      const filename = 'src/MacroToken.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBe('MacroToken');
    });

    it('should extract contract name from nested src/ directory', () => {
      const filename = 'src/contracts/tokens/MyToken.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBe('MyToken');
    });

    it('should extract contract name from deeply nested src/ directory', () => {
      const filename = 'src/features/token/management/TokenController.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBe('TokenController');
    });

    it('should return null for non-Solidity files', () => {
      const filename = 'src/README.md';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBeNull();
    });

    it('should return null for files not in src/ directory', () => {
      const filename = 'test/TestContract.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBeNull();
    });

    it('should return null for files outside src/ directory', () => {
      const filename = 'contracts/MyContract.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBeNull();
    });

    it('should handle files with multiple dots', () => {
      const filename = 'src/MyContract.v2.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBe('MyContract.v2');
    });

    it('should handle files with special characters', () => {
      const filename = 'src/MyContract_V2.sol';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBe('MyContract_V2');
    });

    it('should return null for empty filename', () => {
      const filename = '';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBeNull();
    });

    it('should return null for filename without extension', () => {
      const filename = 'src/MyContract';
      const result = (checker as any).getContractName(filename);
      
      expect(result).toBeNull();
    });
  });
});
