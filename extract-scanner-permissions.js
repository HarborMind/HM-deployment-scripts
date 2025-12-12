#!/usr/bin/env node

/**
 * Extract Scanner Permissions from CloudFormation Template
 *
 * This script reads the AWS-ECS-Fleet-Template-Dynamic.yaml and extracts
 * all IAM policies from the ScannerTaskRole resource to create a JSON file
 * that the frontend can use to display the permissions policy.
 *
 * Run this script before building the frontend to keep policies in sync.
 */

const fs = require('fs');
const path = require('path');

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

  // Extract all policy statements
  const statements = [];
  const policyNames = [];

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
    policyNames.push(policyName);

    // Process each statement in the policy
    policy.PolicyDocument.Statement.forEach(statement => {
      // Clean up CloudFormation intrinsic functions for display
      const cleanedStatement = cleanStatement(statement);
      statements.push(cleanedStatement);
    });

    console.log(`   ✓ Extracted: ${policyName} (${policy.PolicyDocument.Statement.length} statements)`);
  });

  // Create the output JSON
  const output = {
    version: new Date().toISOString().split('T')[0],
    generatedAt: new Date().toISOString(),
    sourceTemplate: 'AWS-ECS-Fleet-Template-Dynamic.yaml',
    roleNamePattern: 'HarborMind-ScannerTaskRole-{region}',
    extractedPolicies: policyNames,
    totalStatements: statements.length,
    permissionsPolicy: {
      Version: '2012-10-17',
      Statement: statements
    }
  };

  // Write the output file
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(output, null, 2));

  console.log('');
  console.log(`✅ Successfully extracted ${statements.length} policy statements from ${policyNames.length} policies`);
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
