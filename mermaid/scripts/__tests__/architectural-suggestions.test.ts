import { SimpleArchitectureChecker } from '../simple-architecture-checker';

describe('Architectural Suggestions', () => {
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

  describe('getArchitecturalSuggestions', () => {
    const mockArchitecture = new Set([
      'MacroToken', 'Controller', 'ERC20', 'UUPS', 'AccessControl',
      'MacroTokenProxy', 'ControllerProxy', 'IMacroToken', 'IController'
    ]);

    it('should suggest similar components for fuzzy matches', () => {
      const contractName = 'MacroTokenV2';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('MacroToken');
    });

    it('should suggest token-related components for token contracts', () => {
      const contractName = 'MyToken';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('MacroToken');
      expect(result).toContain('ERC20');
    });

    it('should suggest controller components for management contracts', () => {
      const contractName = 'TokenManager';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('Controller');
    });

    it('should suggest controller components for admin contracts', () => {
      const contractName = 'AdminController';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('Controller');
    });

    it('should suggest proxy components for proxy contracts', () => {
      const contractName = 'MyProxy';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('MacroTokenProxy');
      expect(result).toContain('ControllerProxy');
    });

    it('should suggest interface components for interface contracts', () => {
      const contractName = 'IMyContract';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('IMacroToken');
      expect(result).toContain('IController');
    });

    it('should provide generic suggestion for unknown contract types', () => {
      const contractName = 'RandomContract';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('Consider updating the target architecture');
    });

    it('should handle empty architecture', () => {
      const contractName = 'MyContract';
      const emptyArchitecture = new Set();
      const result = (checker as any).getArchitecturalSuggestions(contractName, emptyArchitecture);
      
      expect(result).toContain('Consider updating the target architecture');
    });

    it('should combine multiple suggestions', () => {
      const contractName = 'TokenController';
      const result = (checker as any).getArchitecturalSuggestions(contractName, mockArchitecture);
      
      expect(result).toContain('MacroToken');
      expect(result).toContain('Controller');
    });
  });

  describe('getArchitecturalGuidance', () => {
    const mockArchitecture = new Set(['MacroToken', 'Controller']);

    it('should return positive guidance for aligned contracts', () => {
      const contractName = 'MacroToken';
      const result = (checker as any).getArchitecturalGuidance(contractName, mockArchitecture);
      
      expect(result).toContain('✅');
      expect(result).toContain('is part of the target architecture');
    });

    it('should return guidance with suggestions for misaligned contracts', () => {
      const contractName = 'UnknownContract';
      const result = (checker as any).getArchitecturalGuidance(contractName, mockArchitecture);
      
      expect(result).toContain('❌');
      expect(result).toContain('is not in the target architecture');
      expect(result).toContain('Consider updating the target architecture');
    });
  });
});
