#!/usr/bin/env node

/**
 * Extract Scanner Permissions from CloudFormation Template
 *
 * This script reads the AWS-ECS-Fleet-Template-Dynamic.yaml and extracts
 * all IAM policies from the ScannerTaskRole resource to create a JSON file
 * that the frontend can use to display the permissions policy.
 *
 * The policies are split into two managed policies to stay under AWS IAM's
 * 6144 character limit per policy:
 * - HarborMindScannerPolicy: Core data scanning permissions
 * - HarborMindCSPMPolicy: Security monitoring and CSPM permissions
 *
 * Run this script before building the frontend to keep policies in sync.
 */

const fs = require('fs');
const path = require('path');

// AWS IAM limit for managed policies (non-whitespace characters)
const IAM_POLICY_CHAR_LIMIT = 6144;

// Define which policies go into each bucket
const SCANNER_POLICY_NAMES = [
  'S3ReadAccess',
  'RDSReadAccess',
  'DynamoDBReadAccess',
  'RedshiftReadAccess',
  'RedshiftServerlessReadAccess',
  'RedshiftDataAPIAccess',
  'NeptuneReadAccess',
  'NeptuneDataAccess',
  'EC2ReadAccess',
  'FileSystemReadAccess'
];

const CSPM_POLICY_NAMES = [
  'SageMakerReadAccess',
  'GlueReadAccess',
  'BedrockReadAccess',
  'CSPMReadAccess',
  'CloudWatchMetrics',
  'SecretsManagerAccess',
  'KMSDecryptAccess',
  'CrossAccountAssumeRole'
];

// Paths
const SCRIPT_DIR = __dirname;
const FRONTEND_DIR = path.join(SCRIPT_DIR, '../SaaS-frontend');
const TEMPLATE_PATH = path.join(FRONTEND_DIR, 'public/templates/AWS-ECS-Fleet-Template-Dynamic.yaml');
const OUTPUT_PATH = path.join(FRONTEND_DIR, 'public/scanner-permissions.json');

// Try to load js-yaml from the frontend's node_modules
let yaml;
try {
  yaml = require(path.join(FRONTEND_DIR, 'node_modules/js-yaml'));
} catch {
  // Fallback to global or local js-yaml
  yaml = require('js-yaml');
}

// Define custom CloudFormation tags so js-yaml can parse the template
const cfnTags = [
  'Ref', 'Sub', 'Join', 'GetAtt', 'If', 'Not', 'Equals', 'And', 'Or',
  'Condition', 'Base64', 'Cidr', 'FindInMap', 'GetAZs', 'ImportValue',
  'Select', 'Split', 'Transform'
];

// Create a schema that treats CloudFormation intrinsic functions as simple objects
const CFN_SCHEMA = yaml.DEFAULT_SCHEMA.extend(
  cfnTags.map(tag => new yaml.Type(`!${tag}`, {
    kind: 'scalar',
    construct: data => ({ [`Fn::${tag}`]: data })
  })).concat(
    cfnTags.map(tag => new yaml.Type(`!${tag}`, {
      kind: 'sequence',
      construct: data => ({ [`Fn::${tag}`]: data })
    }))
  ).concat(
    cfnTags.map(tag => new yaml.Type(`!${tag}`, {
      kind: 'mapping',
      construct: data => ({ [`Fn::${tag}`]: data })
    }))
  )
);

console.log('📋 Extracting scanner permissions from CloudFormation template...');
console.log(`   Source: ${TEMPLATE_PATH}`);
console.log(`   Output: ${OUTPUT_PATH}`);

// Check if template exists
if (!fs.existsSync(TEMPLATE_PATH)) {
  console.error(`❌ Template not found: ${TEMPLATE_PATH}`);
  process.exit(1);
}

try {
  // Read and parse the CloudFormation template
  const templateContent = fs.readFileSync(TEMPLATE_PATH, 'utf8');
  const template = yaml.load(templateContent, { schema: CFN_SCHEMA });

  // Find the ScannerTaskRole resource
  const scannerTaskRole = template.Resources?.ScannerTaskRole;
  if (!scannerTaskRole) {
    console.error('❌ ScannerTaskRole resource not found in template');
    process.exit(1);
  }

  // Extract all policy statements, organized by policy name
  const scannerStatements = [];
  const cspmStatements = [];
  const scannerPolicyNames = [];
  const cspmPolicyNames = [];

  const policies = scannerTaskRole.Properties?.Policies || [];

  policies.forEach((policy, index) => {
    // Skip conditional policies (Fn::If returns an array)
    if (Array.isArray(policy)) {
      console.log(`   ⏭️  Skipping conditional policy at index ${index}`);
      return;
    }

    // Skip if no PolicyDocument
    if (!policy.PolicyDocument?.Statement) {
      console.log(`   ⏭️  Skipping policy without statements: ${policy.PolicyName || 'unnamed'}`);
      return;
    }

    const policyName = policy.PolicyName || `Policy${index}`;

    // Determine which bucket this policy belongs to
    const isScanner = SCANNER_POLICY_NAMES.includes(policyName);
    const isCspm = CSPM_POLICY_NAMES.includes(policyName);

    if (isScanner) {
      scannerPolicyNames.push(policyName);
      policy.PolicyDocument.Statement.forEach(statement => {
        scannerStatements.push(cleanStatement(statement));
      });
      console.log(`   ✓ Scanner: ${policyName} (${policy.PolicyDocument.Statement.length} statements)`);
    } else if (isCspm) {
      cspmPolicyNames.push(policyName);
      policy.PolicyDocument.Statement.forEach(statement => {
        cspmStatements.push(cleanStatement(statement));
      });
      console.log(`   ✓ CSPM: ${policyName} (${policy.PolicyDocument.Statement.length} statements)`);
    } else {
      // Unknown policy - add to scanner by default
      scannerPolicyNames.push(policyName);
      policy.PolicyDocument.Statement.forEach(statement => {
        scannerStatements.push(cleanStatement(statement));
      });
      console.log(`   ⚠️  Unknown (added to Scanner): ${policyName} (${policy.PolicyDocument.Statement.length} statements)`);
    }
  });

  // Build the two policies
  const scannerPolicy = {
    Version: '2012-10-17',
    Statement: scannerStatements
  };

  const cspmPolicy = {
    Version: '2012-10-17',
    Statement: cspmStatements
  };

  // Calculate character counts
  const scannerChars = JSON.stringify(scannerPolicy).replace(/\s/g, '').length;
  const cspmChars = JSON.stringify(cspmPolicy).replace(/\s/g, '').length;

  console.log('');
  console.log(`   📊 HarborMindScannerPolicy: ${scannerChars} chars (limit: ${IAM_POLICY_CHAR_LIMIT})`);
  console.log(`   📊 HarborMindCSPMPolicy: ${cspmChars} chars (limit: ${IAM_POLICY_CHAR_LIMIT})`);

  if (scannerChars > IAM_POLICY_CHAR_LIMIT) {
    console.warn(`   ⚠️  WARNING: Scanner policy exceeds limit by ${scannerChars - IAM_POLICY_CHAR_LIMIT} chars`);
  }
  if (cspmChars > IAM_POLICY_CHAR_LIMIT) {
    console.warn(`   ⚠️  WARNING: CSPM policy exceeds limit by ${cspmChars - IAM_POLICY_CHAR_LIMIT} chars`);
  }

  // Create the output JSON with both policies
  const output = {
    version: new Date().toISOString().split('T')[0],
    generatedAt: new Date().toISOString(),
    sourceTemplate: 'AWS-ECS-Fleet-Template-Dynamic.yaml',
    roleNamePattern: 'HarborMind-ScannerTaskRole-{region}',
    policies: [
      {
        name: 'HarborMindScannerPolicy',
        description: 'Core data scanning permissions for S3, RDS, DynamoDB, Redshift, Neptune, EFS, and EC2',
        extractedFrom: scannerPolicyNames,
        statementCount: scannerStatements.length,
        characterCount: scannerChars,
        policy: scannerPolicy
      },
      {
        name: 'HarborMindCSPMPolicy',
        description: 'Security monitoring and CSPM permissions for IAM, CloudTrail, GuardDuty, Security Hub, and more',
        extractedFrom: cspmPolicyNames,
        statementCount: cspmStatements.length,
        characterCount: cspmChars,
        policy: cspmPolicy
      }
    ],
    totalStatements: scannerStatements.length + cspmStatements.length,
    // Keep legacy field for backwards compatibility
    permissionsPolicy: scannerPolicy
  };

  // Write the output file
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(output, null, 2));

  console.log('');
  console.log(`✅ Successfully extracted ${scannerStatements.length + cspmStatements.length} policy statements`);
  console.log(`   - HarborMindScannerPolicy: ${scannerStatements.length} statements from ${scannerPolicyNames.length} policies`);
  console.log(`   - HarborMindCSPMPolicy: ${cspmStatements.length} statements from ${cspmPolicyNames.length} policies`);
  console.log(`   Output written to: ${OUTPUT_PATH}`);

} catch (error) {
  console.error('❌ Error extracting permissions:', error.message);
  process.exit(1);
}

/**
 * Clean up CloudFormation intrinsic functions from a policy statement
 * for display purposes. Replaces ${AWS::Region} and ${AWS::AccountId}
 * with placeholder text.
 */
function cleanStatement(statement) {
  const cleaned = JSON.parse(JSON.stringify(statement));

  // Process the Resource field
  if (cleaned.Resource) {
    cleaned.Resource = cleanResource(cleaned.Resource);
  }

  // Process Condition if present
  if (cleaned.Condition) {
    cleaned.Condition = cleanCondition(cleaned.Condition);
  }

  return cleaned;
}

/**
 * Clean Resource field - handle strings, arrays, and intrinsic functions
 */
function cleanResource(resource) {
  if (typeof resource === 'string') {
    return cleanResourceString(resource);
  }

  if (Array.isArray(resource)) {
    return resource.map(r => cleanResource(r));
  }

  // Handle Fn::Sub
  if (resource['Fn::Sub']) {
    const subValue = resource['Fn::Sub'];
    if (typeof subValue === 'string') {
      return cleanResourceString(subValue);
    }
    if (Array.isArray(subValue)) {
      return cleanResourceString(subValue[0]);
    }
  }

  // Handle !Sub (same as Fn::Sub in parsed YAML)
  if (resource['!Sub']) {
    return cleanResourceString(resource['!Sub']);
  }

  // Handle Fn::Join
  if (resource['Fn::Join']) {
    const [separator, parts] = resource['Fn::Join'];
    const cleanedParts = parts.map(p => {
      if (typeof p === 'string') return p;
      if (p['Ref'] === 'AWS::Region') return '{region}';
      if (p['Ref'] === 'AWS::AccountId') return '{accountId}';
      return '{ref}';
    });
    return cleanedParts.join(separator);
  }

  return resource;
}

/**
 * Clean a resource string by replacing CloudFormation variables
 */
function cleanResourceString(str) {
  return str
    .replace(/\$\{AWS::Region\}/g, '{region}')
    .replace(/\$\{AWS::AccountId\}/g, '{accountId}')
    .replace(/\$\{[^}]+\}/g, '{ref}'); // Replace other refs with generic placeholder
}

/**
 * Clean Condition field
 */
function cleanCondition(condition) {
  const cleaned = JSON.parse(JSON.stringify(condition));

  // Recursively clean string values
  Object.keys(cleaned).forEach(key => {
    const value = cleaned[key];
    if (typeof value === 'object' && value !== null) {
      Object.keys(value).forEach(innerKey => {
        const innerValue = value[innerKey];
        if (typeof innerValue === 'string') {
          value[innerKey] = cleanResourceString(innerValue);
        } else if (Array.isArray(innerValue)) {
          value[innerKey] = innerValue.map(v =>
            typeof v === 'string' ? cleanResourceString(v) : v
          );
        }
      });
    }
  });

  return cleaned;
}
