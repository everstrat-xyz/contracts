/**
 * Simple Architecture Checker
 * Minimal tool to check if PR changes match Mermaid architecture diagram
 */

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { Octokit } from '@octokit/rest';

// ES module compatibility
const currentFilename = fileURLToPath(import.meta.url);
const currentDirname = path.dirname(currentFilename);

interface SimpleConfig {
  github_token: string;
  repo: string;
  mermaid_file: string;
}

interface PRFile {
  filename: string;
  status: string;
}

class SimpleArchitectureChecker {
  private config: SimpleConfig;
  private octokit: Octokit;
  private mermaidComponents: Set<string> = new Set();
  
  // Mermaid keywords to filter out during parsing
  private static readonly MERMAID_KEYWORDS = new Set([
    'Variables', 'Size', 'TextColor', 'Spacing', 'TB', 'External', 'Libraries',
    'Top', 'Level', 'Proxy', 'Layer', 'Interfaces', 'Main', 'Contracts',
    'Green', 'Boxes', 'Tests', 'Deployment', 'Relationships', 'Styling',
    'Def', 'EE90', 'CEEB', 'B4', 'E6E6FA', 'B0082', 'F0E68C', 'B8860B',
    'FB98', 'B22', 'DDA0DD', 'B008B', 'graph', 'subgraph', 'end', 'classDef',
    'class', 'style', 'linkStyle', 'click', 'direction'
  ]);

  constructor(token?: string, repo?: string) {
    const githubToken = token || process.env.GITHUB_TOKEN;
    const githubRepo = repo || process.env.GITHUB_REPO;

    if (!githubToken) {
      throw new Error('GITHUB_TOKEN environment variable is required');
    }

    if (!githubRepo) {
      throw new Error('GITHUB_REPO environment variable is required');
    }

    // Validate repository format (owner/repo)
    if (!githubRepo.includes('/') || githubRepo.split('/').length !== 2) {
      throw new Error('GITHUB_REPO must be in format "owner/repo"');
    }
    
    // More robust path resolution
    const scriptDir = currentDirname || path.dirname(fileURLToPath(import.meta.url));
    const mermaidFile = process.env.MERMAID_FILE || path.resolve(scriptDir, '../mermaid-smart-contracts.md');
    
    this.config = {
      github_token: githubToken,
      repo: githubRepo,
      mermaid_file: mermaidFile
    };
    
    this.octokit = new Octokit({ auth: this.config.github_token });
    this.loadMermaidComponents();
  }

  /**
   * Parse Mermaid content and extract component names
   */
  private parseMermaidComponents(content: string): Set<string> {
    const components = new Set<string>();
    
    // Look for the "Future Architecture Overview" section specifically
    const futureArchMatch = content.match(/## Future Architecture Overview\s*\n\s*```mermaid\n([\s\S]*?)\n\s*```/);
    
    if (futureArchMatch?.[1]) {
      const mermaidContent = futureArchMatch[1];
      
      // Improved regex to handle more edge cases
      // Matches: ComponentName, ComponentName["label"], componentName (lowercase), etc.
      const componentMatches = mermaidContent.match(/([a-zA-Z][a-zA-Z0-9]*)(?:\[[^\]]*\])?(?=\s*[\[\-\.\s]|$)/g);
      
      if (componentMatches) {
        componentMatches.forEach(match => {
          const componentName = match.split('[')[0].trim();
          // Only add if it's not a keyword and has reasonable length
          if (!SimpleArchitectureChecker.MERMAID_KEYWORDS.has(componentName) && componentName.length > 1) {
            components.add(componentName);
          }
        });
      }
    } else {
      console.error('❌ Future Architecture Overview section not found in mermaid file');
      console.error('The architectural guidance requires a "## Future Architecture Overview" section with a mermaid diagram');
      throw new Error('Future Architecture Overview section not found');
    }
    
    return components;
  }

  /**
   * Load component names from Mermaid diagram
   * This loads the CURRENT architecture (existing on the branch)
   */
  private loadMermaidComponents(): void {
    try {
      const content = fs.readFileSync(this.config.mermaid_file, 'utf8');
      this.mermaidComponents = this.parseMermaidComponents(content);
    } catch (error) {
      console.error('Error loading Mermaid components:', error);
      throw new Error(`Failed to load Mermaid components from ${this.config.mermaid_file}: ${error}`);
    }
  }

  /**
   * Load the TARGET architecture (the intended future state)
   * This should be the architecture we're working toward
   */
  private async loadTargetArchitecture(): Promise<Set<string>> {
    try {
      // Always use the current architecture as the target
      // In a real scenario, this might be a separate "target-architecture.md" file
      const content = fs.readFileSync(this.config.mermaid_file, 'utf8');
      const targetComponents = this.parseMermaidComponents(content);
      
      console.log(`🎯 Loaded target architecture with ${targetComponents.size} components:`, Array.from(targetComponents));
      return targetComponents;
    } catch (error) {
      console.error('Error loading target architecture:', error);
      return this.mermaidComponents;
    }
  }

  /**
   * Check if a contract aligns with the target architecture
   */
  private isAlignedWithTarget(contractName: string, targetArchitecture: Set<string>): boolean {
    return targetArchitecture.has(contractName);
  }

  /**
   * Get architectural guidance for a contract
   */
  private getArchitecturalGuidance(contractName: string, targetArchitecture: Set<string>): string {
    if (targetArchitecture.has(contractName)) {
      return `✅ ${contractName} is part of the target architecture`;
    } else {
      const suggestions = this.getArchitecturalSuggestions(contractName, targetArchitecture);
      return `❌ ${contractName} is not in the target architecture. ${suggestions}`;
    }
  }

  /**
   * Provide architectural suggestions based on target architecture
   */
  private getArchitecturalSuggestions(contractName: string, targetArchitecture: Set<string>): string {
    const suggestions = [];
    
    // Check for similar names (fuzzy matching)
    const similarComponents = Array.from(targetArchitecture).filter(component => 
      component.toLowerCase().includes(contractName.toLowerCase()) ||
      contractName.toLowerCase().includes(component.toLowerCase())
    );
    
    if (similarComponents.length > 0) {
      suggestions.push(`Did you mean: ${similarComponents.join(', ')}?`);
    }
    
    // Architecture-aware suggestions based on actual components
    const architectureComponents = Array.from(targetArchitecture);
    
    // Check for token-related contracts
    if (contractName.toLowerCase().includes('token')) {
      const tokenComponents = architectureComponents.filter(c => 
        c.toLowerCase().includes('token') || c.toLowerCase().includes('erc20')
      );
      if (tokenComponents.length > 0) {
        suggestions.push(`Consider if this should be part of: ${tokenComponents.join(', ')}`);
      }
    }
    
    // Check for controller/management contracts
    if (contractName.toLowerCase().includes('controller') || 
        contractName.toLowerCase().includes('manager') ||
        contractName.toLowerCase().includes('admin')) {
      const controllerComponents = architectureComponents.filter(c => 
        c.toLowerCase().includes('controller') || c.toLowerCase().includes('manager')
      );
      if (controllerComponents.length > 0) {
        suggestions.push(`Consider if this should be part of: ${controllerComponents.join(', ')}`);
      }
    }
    
    // Check for proxy contracts
    if (contractName.toLowerCase().includes('proxy')) {
      const proxyComponents = architectureComponents.filter(c => 
        c.toLowerCase().includes('proxy')
      );
      if (proxyComponents.length > 0) {
        suggestions.push(`Consider if this should be part of: ${proxyComponents.join(', ')}`);
      }
    }
    
    // Check for interface contracts
    if (contractName.toLowerCase().startsWith('i') && contractName.length > 1) {
      const interfaceComponents = architectureComponents.filter(c => 
        c.toLowerCase().startsWith('i') && c.length > 1
      );
      if (interfaceComponents.length > 0) {
        suggestions.push(`Consider if this should be part of: ${interfaceComponents.join(', ')}`);
      }
    }
    
    if (suggestions.length === 0) {
      suggestions.push('Consider updating the target architecture to include this component if it\'s needed');
    }
    
    return suggestions.join(' ');
  }

  /**
   * Generate summary for GitHub Actions output
   */
  private generateSummary(
    architecturalIssues: string[], 
    hasNewContracts: boolean, 
    architectureUpdated: boolean, 
    alignedContracts: string[], 
    newContracts: string[]
  ): string {
    if (architecturalIssues.length === 0 && (!hasNewContracts || architectureUpdated)) {
      return 'All changes align with target architecture and documentation is up to date';
    }
    
    const parts = [];
    
    if (architecturalIssues.length > 0) {
      parts.push(`${architecturalIssues.length} architectural guidance items`);
    }
    
    if (hasNewContracts && !architectureUpdated) {
      parts.push('new contracts without architecture documentation');
    }
    
    if (architectureUpdated && !hasNewContracts) {
      parts.push('architecture updated without new contracts');
    }
    
    if (alignedContracts.length > 0) {
      parts.push(`${alignedContracts.length} well-aligned contracts`);
    }
    
    return parts.join(', ');
  }

  /**
   * Output results to GitHub Actions or console
   */
  private outputResults(output: any): void {
    const githubOutput = process.env.GITHUB_OUTPUT;
    if (githubOutput) {
      const outputData = [
        `status=${output.status}`,
        `summary=${output.summary}`,
        `architecture_issues_count=${output.details.architecturalIssues}`,
        `new_contracts=${output.details.newContracts}`,
        `aligned_contracts=${output.details.alignedContracts}`,
        `architecture_updated=${output.details.architectureUpdated}`,
        `has_new_contracts=${output.details.hasNewContracts}`,
        `undocumented_contracts=${output.details.undocumentedContracts.join(',')}`,
        `output_json=${JSON.stringify(output)}`
      ].join('\n');
      
      fs.appendFileSync(githubOutput, outputData + '\n');
    } else {
      // Fallback to console output for local testing
      console.log('Status:', output.status);
      console.log('Summary:', output.summary);
      console.log('Architectural Issues:', output.details.architecturalIssues);
      console.log('New Contracts:', output.details.newContracts);
      console.log('Aligned Contracts:', output.details.alignedContracts);
      console.log('Architecture Updated:', output.details.architectureUpdated);
      console.log('Has New Contracts:', output.details.hasNewContracts);
      console.log('Undocumented Contracts:', output.details.undocumentedContracts.join(','));
      console.log('Output JSON:', JSON.stringify(output));
    }
  }

  /**
   * Generate recommendations for GitHub Actions output
   */
  private generateRecommendations(
    architecturalIssues: string[],
    hasNewContracts: boolean,
    architectureUpdated: boolean,
    newContracts: string[],
    targetArchitecture: Set<string>
  ): string[] {
    const recommendations = [];
    
    if (architecturalIssues.length > 0) {
      recommendations.push('Review architectural guidance and align with target architecture');
    }
    
    if (hasNewContracts && !architectureUpdated) {
      recommendations.push('Update architecture documentation to include new contracts');
    }
    
    if (architectureUpdated && !hasNewContracts) {
      recommendations.push('Verify architecture changes are necessary and properly documented');
    }
    
    const undocumentedContracts = newContracts.filter(contract => !targetArchitecture.has(contract));
    if (undocumentedContracts.length > 0) {
      recommendations.push(`Document these contracts: ${undocumentedContracts.join(', ')}`);
    }
    
    return recommendations;
  }

  /**
   * Check if a contract name exists in architecture
   */
  private isInArchitecture(contractName: string): boolean {
    return this.mermaidComponents.has(contractName);
  }

  /**
   * Extract contract name from file path
   * Handles contracts in src/ and any subdirectories
   */
  private getContractName(filename: string): string | null {
    if (filename.endsWith('.sol') && filename.includes('src/')) {
      // Extract filename from any path within src/
      const pathParts = filename.split('/');
      const srcIndex = pathParts.indexOf('src');
      if (srcIndex !== -1 && srcIndex < pathParts.length - 1) {
        const fileName = pathParts[pathParts.length - 1];
        return fileName.replace('.sol', '');
      }
    }
    return null;
  }

  /**
   * Check PR against target architecture and provide guidance
   */
  public async checkPR(prNumber: number): Promise<void> {
    try {
      console.log(`🔍 Checking PR #${prNumber} against target architecture...`);
      
      // Check if we're in mock mode for testing
      if (process.env.ARCHITECTURE_CHECKER_MOCK === 'true') {
        console.log('🧪 Running in mock mode - using sample data');
        const mockOutput = {
          status: 'success',
          summary: 'Mock analysis completed - no real GitHub API calls made',
          details: {
            architecturalIssues: 0,
            newContracts: 2,
            alignedContracts: 2,
            architectureUpdated: false,
            hasNewContracts: true,
            undocumentedContracts: []
          }
        };
        this.outputResults(mockOutput);
        console.log(`✅ Mock architecture guidance check completed for PR #${prNumber}`);
        return;
      }
      
      // Get PR files
      const { data: files } = await this.octokit.pulls.listFiles({
        owner: this.config.repo.split('/')[0],
        repo: this.config.repo.split('/')[1],
        pull_number: prNumber,
      });

      // Load the target architecture (the intended future state)
      const targetArchitecture = await this.loadTargetArchitecture();
      
      const architecturalIssues: string[] = [];
      const newContracts: string[] = [];
      const alignedContracts: string[] = [];
      const architectureUpdated = files.some(file => 
        file.filename === this.config.mermaid_file && 
        (file.status === 'added' || file.status === 'modified')
      );
      
      // Check if new contracts were added but architecture wasn't updated
      const hasNewContracts = files.some(file => {
        const contractName = this.getContractName(file.filename);
        return contractName && (file.status === 'added' || file.status === 'modified');
      });

      // Check each file against the target architecture
      for (const file of files) {
        if (file.status === 'added' || file.status === 'modified') {
          const contractName = this.getContractName(file.filename);
          if (contractName) {
            newContracts.push(contractName);
            
            if (this.isAlignedWithTarget(contractName, targetArchitecture)) {
              alignedContracts.push(contractName);
            } else {
              const guidance = this.getArchitecturalGuidance(contractName, targetArchitecture);
              architecturalIssues.push(guidance);
            }
          }
        }
      }

      // Generate comment
      let comment = '## 🎯 Architecture Guidance Check\n\n';
      comment += 'This check validates that your changes align with the **target architecture** and provides guidance for moving in the right direction.\n\n';
      
      if (architectureUpdated && hasNewContracts) {
        comment += '📝 **Architecture diagram updated in this PR**\n\n';
      } else if (architectureUpdated && !hasNewContracts) {
        comment += '📝 **Architecture diagram updated (no new contracts detected)**\n\n';
        comment += 'The architecture diagram was modified but no new contracts were detected. Please ensure the changes are necessary and properly documented.\n\n';
      } else if (hasNewContracts && !architectureUpdated) {
        comment += '⚠️ **Architecture documentation not updated**\n\n';
        comment += 'This PR adds new contracts but doesn\'t update the architecture diagram. Please consider updating `mermaid/mermaid-smart-contracts.md` to document the new components.\n\n';
      }
      
      if (alignedContracts.length > 0) {
        comment += '✅ **Well-aligned contracts:**\n';
        alignedContracts.forEach(contract => {
          comment += `- ${contract}\n`;
        });
        comment += '\n';
      }

      if (architecturalIssues.length > 0) {
        comment += '⚠️ **Architectural guidance needed:**\n\n';
        architecturalIssues.forEach(issue => {
          comment += `- ${issue}\n`;
        });
        comment += '\n';
        comment += '💡 **Next steps:**\n';
        comment += '- Review the target architecture to understand the intended design\n';
        comment += '- Consider if new contracts should be part of existing components\n';
        comment += '- Update the target architecture if new components are genuinely needed\n\n';
      }

      // Add specific guidance for undocumented new contracts
      if (hasNewContracts && !architectureUpdated) {
        const undocumentedContracts = newContracts.filter(contract => 
          !targetArchitecture.has(contract)
        );
        
        if (undocumentedContracts.length > 0) {
          comment += '📋 **New contracts that need documentation:**\n';
          undocumentedContracts.forEach(contract => {
            comment += `- ${contract}\n`;
          });
          comment += '\n';
          comment += '💡 **Documentation steps:**\n';
          comment += '1. Add the new contracts to the Mermaid diagram in `mermaid/mermaid-smart-contracts.md`\n';
          comment += '2. Define relationships between new contracts and existing components\n';
          comment += '3. Update the diagram styling if needed\n\n';
        }
      }

      if (newContracts.length === 0) {
        comment += '📋 **No new contracts detected in this PR**\n\n';
      }

      // Add target architecture reference
      comment += '## 🏗️ Target Architecture Components\n\n';
      comment += 'The following components are part of the target architecture:\n';
      Array.from(targetArchitecture).forEach(component => {
        comment += `- ${component}\n`;
      });
      comment += '\n';

      comment += '---\n*Automated architecture guidance to help you build toward the target design*';

      // Post comment
      await this.octokit.issues.createComment({
        owner: this.config.repo.split('/')[0],
        repo: this.config.repo.split('/')[1],
        issue_number: prNumber,
        body: comment,
      });

      // Generate structured output for GitHub Actions
      const output = {
        status: architecturalIssues.length === 0 && (!hasNewContracts || architectureUpdated) ? 'success' : 'warning',
        summary: this.generateSummary(architecturalIssues, hasNewContracts, architectureUpdated, alignedContracts, newContracts),
        details: {
          architecturalIssues: architecturalIssues.length,
          newContracts: newContracts.length,
          alignedContracts: alignedContracts.length,
          architectureUpdated: architectureUpdated,
          hasNewContracts: hasNewContracts,
          undocumentedContracts: newContracts.filter(contract => !targetArchitecture.has(contract))
        },
        recommendations: this.generateRecommendations(architecturalIssues, hasNewContracts, architectureUpdated, newContracts, targetArchitecture)
      };

      // Output structured data for GitHub Actions
      this.outputResults(output);
      
      console.log(`✅ Architecture guidance check completed for PR #${prNumber}`);
      console.log(`Status: ${output.status}`);
      console.log(`Summary: ${output.summary}`);

    } catch (error) {
      console.error('❌ Error checking PR:', error);
      
      // Provide fallback output even when GitHub API fails
      const fallbackOutput = {
        status: 'error',
        summary: `Failed to analyze PR #${prNumber}: ${error instanceof Error ? error.message : 'Unknown error'}`,
        details: {
          architecturalIssues: 0,
          newContracts: 0,
          alignedContracts: 0,
          architectureUpdated: false,
          hasNewContracts: false,
          undocumentedContracts: []
        }
      };
      
      this.outputResults(fallbackOutput);
      throw error;
    }
  }
}

// CLI usage
async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log('Usage: ts-node simple-architecture-checker.ts <PR_NUMBER>');
    process.exit(1);
  }

  const prNumber = parseInt(args[0]);
  if (isNaN(prNumber)) {
    console.error('❌ Invalid PR number');
    process.exit(1);
  }

  try {
    const checker = new SimpleArchitectureChecker();
    await checker.checkPR(prNumber);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }
}

// Run main if executed directly (ES module approach)
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

export { SimpleArchitectureChecker };
