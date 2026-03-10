#!/usr/bin/env python3
"""
Seed Master Integrations and Integration Configs Tables

Populates two DynamoDB tables:
1. master-integrations: AWS and M365 service definitions with feature flags (CSPM, Assets, Data Discovery)
2. master-integration-configs: Default scan configuration settings per integration type

Usage:
    python seed-master-integrations.py --environment dev
    python seed-master-integrations.py --environment dev --dry-run
    python seed-master-integrations.py --environment dev --verify
    python seed-master-integrations.py --environment dev --configs-only
    python seed-master-integrations.py --environment dev --verify-configs
"""

import argparse
import boto3
import logging
from datetime import datetime, timezone
from typing import Dict, List, Any

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# Services with Assets feature enabled (per requirements)
# AWS: IAM, Bedrock, EC2, Lambda, ECS, EKS
# M365: Entra ID, Intune
ASSETS_ENABLED_SERVICES = {
    "iam", "bedrock", "ec2", "lambda", "ecs", "eks",
    "entraid", "intune"
}

# Services with Data Discovery enabled (per requirements)
# AWS: S3, DynamoDB, EC2, EFS, FSx, Neptune, RDS, Redshift
# M365: SharePoint, OneDrive
# Note: DocumentDB removed - data scanning not yet implemented
DATA_DISCOVERY_ENABLED_SERVICES = {
    "s3", "dynamodb", "ec2", "efs", "fsx", "neptune", "rds", "redshift",
    "sharepoint", "onedrive"
}

# Complete list of 84 AWS services organized by category
# Based on discovery_metadata collectors
AWS_SERVICES: List[Dict[str, Any]] = [
    # ==================== Storage (9 services) ====================
    {"service": "s3", "displayName": "S3 (Simple Storage Service)", "category": "storage", "description": "Object storage for data storage and retrieval"},
    {"service": "efs", "displayName": "EFS (Elastic File System)", "category": "storage", "description": "Fully managed elastic NFS file system"},
    {"service": "fsx", "displayName": "FSx", "category": "storage", "description": "Fully managed file systems (Windows, Lustre, ONTAP, OpenZFS)"},
    {"service": "glacier", "displayName": "S3 Glacier", "category": "storage", "description": "Low-cost archive storage"},
    {"service": "backup", "displayName": "AWS Backup", "category": "storage", "description": "Centralized backup service"},
    {"service": "storagegateway", "displayName": "Storage Gateway", "category": "storage", "description": "Hybrid cloud storage integration"},
    {"service": "transfer", "displayName": "Transfer Family", "category": "storage", "description": "SFTP, FTPS, and FTP transfers to S3"},
    {"service": "dlm", "displayName": "Data Lifecycle Manager", "category": "storage", "description": "Automated EBS snapshot and AMI management"},
    {"service": "ecr", "displayName": "ECR (Container Registry)", "category": "storage", "description": "Docker container image registry"},

    # ==================== Database (9 services) ====================
    {"service": "dynamodb", "displayName": "DynamoDB", "category": "database", "description": "Fully managed NoSQL database"},
    {"service": "rds", "displayName": "RDS (Relational Database Service)", "category": "database", "description": "Managed relational databases"},
    {"service": "documentdb", "displayName": "DocumentDB", "category": "database", "description": "MongoDB-compatible document database"},
    {"service": "neptune", "displayName": "Neptune", "category": "database", "description": "Fully managed graph database"},
    {"service": "redshift", "displayName": "Redshift", "category": "database", "description": "Data warehouse service"},
    {"service": "elasticache", "displayName": "ElastiCache", "category": "database", "description": "In-memory caching (Redis, Memcached)"},
    {"service": "memorydb", "displayName": "MemoryDB", "category": "database", "description": "Redis-compatible in-memory database"},
    {"service": "dax", "displayName": "DAX (DynamoDB Accelerator)", "category": "database", "description": "In-memory cache for DynamoDB"},
    {"service": "dms", "displayName": "DMS (Database Migration Service)", "category": "database", "description": "Database migration and replication"},

    # ==================== Compute (10 services) ====================
    {"service": "ec2", "displayName": "EC2 (Elastic Compute Cloud)", "category": "compute", "description": "Virtual servers in the cloud"},
    {"service": "lambda", "displayName": "Lambda", "category": "compute", "description": "Serverless compute service"},
    {"service": "ecs", "displayName": "ECS (Elastic Container Service)", "category": "compute", "description": "Docker container orchestration"},
    {"service": "eks", "displayName": "EKS (Elastic Kubernetes Service)", "category": "compute", "description": "Managed Kubernetes service"},
    {"service": "elasticbeanstalk", "displayName": "Elastic Beanstalk", "category": "compute", "description": "Application deployment platform"},
    {"service": "apprunner", "displayName": "App Runner", "category": "compute", "description": "Containerized web app deployment"},
    {"service": "autoscaling", "displayName": "Auto Scaling", "category": "compute", "description": "Automatic scaling for EC2"},
    {"service": "emr", "displayName": "EMR (Elastic MapReduce)", "category": "compute", "description": "Big data processing framework"},
    {"service": "appstream", "displayName": "AppStream 2.0", "category": "compute", "description": "Application streaming service"},
    {"service": "workspaces", "displayName": "WorkSpaces", "category": "compute", "description": "Virtual desktops in the cloud"},

    # ==================== Security (15 services) ====================
    {"service": "iam", "displayName": "IAM (Identity and Access Management)", "category": "security", "description": "Access control and identity management"},
    {"service": "guardduty", "displayName": "GuardDuty", "category": "security", "description": "Intelligent threat detection"},
    {"service": "securityhub", "displayName": "Security Hub", "category": "security", "description": "Security and compliance center"},
    {"service": "macie", "displayName": "Macie", "category": "security", "description": "Sensitive data discovery"},
    {"service": "inspector", "displayName": "Inspector", "category": "security", "description": "Automated security assessment"},
    {"service": "waf", "displayName": "WAF (Web Application Firewall)", "category": "security", "description": "Web application firewall"},
    {"service": "shield", "displayName": "Shield", "category": "security", "description": "DDoS protection"},
    {"service": "config", "displayName": "AWS Config", "category": "security", "description": "Resource configuration tracking"},
    {"service": "kms", "displayName": "KMS (Key Management Service)", "category": "security", "description": "Encryption key management"},
    {"service": "secretsmanager", "displayName": "Secrets Manager", "category": "security", "description": "Secrets rotation and management"},
    {"service": "accessanalyzer", "displayName": "IAM Access Analyzer", "category": "security", "description": "Resource access analysis"},
    {"service": "acm", "displayName": "ACM (Certificate Manager)", "category": "security", "description": "SSL/TLS certificate management"},
    {"service": "cognito", "displayName": "Cognito", "category": "security", "description": "User authentication and authorization"},
    {"service": "fms", "displayName": "Firewall Manager", "category": "security", "description": "Central firewall rule management"},
    {"service": "networkfirewall", "displayName": "Network Firewall", "category": "security", "description": "Managed network firewall"},

    # ==================== Networking (9 services) ====================
    {"service": "vpc", "displayName": "VPC (Virtual Private Cloud)", "category": "networking", "description": "Isolated cloud network"},
    {"service": "elb", "displayName": "ELB Classic", "category": "networking", "description": "Classic load balancer"},
    {"service": "elbv2", "displayName": "ELB v2 (ALB/NLB)", "category": "networking", "description": "Application and network load balancers"},
    {"service": "route53", "displayName": "Route 53", "category": "networking", "description": "DNS and domain management"},
    {"service": "cloudfront", "displayName": "CloudFront", "category": "networking", "description": "Content delivery network (CDN)"},
    {"service": "directconnect", "displayName": "Direct Connect", "category": "networking", "description": "Dedicated network connection"},
    {"service": "globalaccelerator", "displayName": "Global Accelerator", "category": "networking", "description": "Global network performance optimization"},
    {"service": "apigatewayv2", "displayName": "API Gateway v2", "category": "networking", "description": "HTTP and WebSocket APIs"},
    {"service": "apigateway", "displayName": "API Gateway", "category": "networking", "description": "REST API management"},

    # ==================== AI/ML (3 services) ====================
    {"service": "bedrock", "displayName": "Bedrock", "category": "ai_ml", "description": "Foundation models for generative AI"},
    {"service": "sagemaker", "displayName": "SageMaker", "category": "ai_ml", "description": "Machine learning platform"},
    {"service": "amazon_q", "displayName": "Amazon Q", "category": "ai_ml", "description": "AI-powered assistant"},

    # ==================== Analytics (7 services) ====================
    {"service": "athena", "displayName": "Athena", "category": "analytics", "description": "Interactive query service for S3"},
    {"service": "glue", "displayName": "Glue", "category": "analytics", "description": "ETL and data catalog service"},
    {"service": "kinesis", "displayName": "Kinesis Data Streams", "category": "analytics", "description": "Real-time data streaming"},
    {"service": "firehose", "displayName": "Kinesis Firehose", "category": "analytics", "description": "Data delivery to destinations"},
    {"service": "opensearch", "displayName": "OpenSearch", "category": "analytics", "description": "Search and analytics engine"},
    {"service": "lakeformation", "displayName": "Lake Formation", "category": "analytics", "description": "Data lake management"},
    {"service": "msk", "displayName": "MSK (Managed Streaming for Kafka)", "category": "analytics", "description": "Managed Apache Kafka"},

    # ==================== Integration/Messaging (9 services) ====================
    {"service": "sns", "displayName": "SNS (Simple Notification Service)", "category": "integration", "description": "Pub/sub messaging"},
    {"service": "sqs", "displayName": "SQS (Simple Queue Service)", "category": "integration", "description": "Message queuing"},
    {"service": "ses", "displayName": "SES (Simple Email Service)", "category": "integration", "description": "Email sending and receiving"},
    {"service": "eventbridge", "displayName": "EventBridge", "category": "integration", "description": "Serverless event bus"},
    {"service": "stepfunctions", "displayName": "Step Functions", "category": "integration", "description": "Workflow orchestration"},
    {"service": "mq", "displayName": "Amazon MQ", "category": "integration", "description": "Managed message broker"},
    {"service": "appsync", "displayName": "AppSync", "category": "integration", "description": "Managed GraphQL service"},
    {"service": "amplify", "displayName": "Amplify", "category": "integration", "description": "Full-stack app development"},
    {"service": "iot", "displayName": "IoT Core", "category": "integration", "description": "IoT device connectivity"},

    # ==================== Management (13 services) ====================
    {"service": "cloudtrail", "displayName": "CloudTrail", "category": "management", "description": "AWS API logging and auditing"},
    {"service": "cloudwatch", "displayName": "CloudWatch", "category": "management", "description": "Monitoring and observability"},
    {"service": "cloudformation", "displayName": "CloudFormation", "category": "management", "description": "Infrastructure as code"},
    {"service": "ssm", "displayName": "Systems Manager", "category": "management", "description": "Operations management"},
    {"service": "organizations", "displayName": "Organizations", "category": "management", "description": "Multi-account management"},
    {"service": "ram", "displayName": "RAM (Resource Access Manager)", "category": "management", "description": "Cross-account resource sharing"},
    {"service": "servicecatalog", "displayName": "Service Catalog", "category": "management", "description": "IT service catalog"},
    {"service": "directoryservice", "displayName": "Directory Service", "category": "management", "description": "Managed Active Directory"},
    {"service": "drs", "displayName": "DRS (Disaster Recovery Service)", "category": "management", "description": "Disaster recovery"},
    {"service": "codebuild", "displayName": "CodeBuild", "category": "management", "description": "Build service"},
    {"service": "codepipeline", "displayName": "CodePipeline", "category": "management", "description": "CI/CD pipelines"},
    {"service": "codedeploy", "displayName": "CodeDeploy", "category": "management", "description": "Deployment automation"},
]

# Microsoft 365 services
M365_SERVICES: List[Dict[str, Any]] = [
    # Identity & Access (Assets)
    {"service": "entraid", "displayName": "Entra ID (Azure AD)", "category": "identity", "description": "Users, groups, and identity management"},

    # Device Management (Assets)
    {"service": "intune", "displayName": "Intune", "category": "management", "description": "Device management and compliance"},

    # Collaboration & Storage (Data Discovery)
    {"service": "sharepoint", "displayName": "SharePoint Online", "category": "collaboration", "description": "Document management and collaboration"},
    {"service": "onedrive", "displayName": "OneDrive for Business", "category": "storage", "description": "Personal cloud storage"},
]

# Default scan configuration settings for integration types
# These are copied to new integrations when they are created
# Format matches what discovery-processor expects: integrationType, configVersion, defaultConfig
INTEGRATION_CONFIGS: List[Dict[str, Any]] = [
    # Storage
    {
        "integrationType": "aws-s3",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "max_file_size_mb": 100,
                "file_types": ["*"],
                "exclude_patterns": []
            },
            "operational_settings": {
                "batch_size": 1000,
                "concurrent_scans": 5,
                "timeout_seconds": 3600,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-efs",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "max_file_size_mb": 100,
                "scan_depth": 10
            },
            "operational_settings": {
                "batch_size": 500,
                "concurrent_scans": 3,
                "timeout_seconds": 7200,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-fsx",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "max_file_size_mb": 100,
                "scan_depth": 10
            },
            "operational_settings": {
                "batch_size": 500,
                "concurrent_scans": 3,
                "timeout_seconds": 7200,
                "retry_attempts": 3
            }
        }
    },
    # Database
    {
        "integrationType": "aws-dynamodb",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "sample_size": 1000,
                "include_all_tables": True,
                "exclude_tables": []
            },
            "operational_settings": {
                "read_capacity_percent": 25,
                "concurrent_tables": 3,
                "timeout_seconds": 3600,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-rds",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "sample_size": 1000,
                "include_all_databases": True,
                "exclude_databases": ["information_schema", "mysql", "performance_schema", "sys"]
            },
            "operational_settings": {
                "connection_timeout_seconds": 30,
                "query_timeout_seconds": 300,
                "concurrent_tables": 5,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-neptune",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "sample_size": 1000,
                "scan_vertices": True,
                "scan_edges": True
            },
            "operational_settings": {
                "connection_timeout_seconds": 30,
                "query_timeout_seconds": 300,
                "batch_size": 500,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-redshift",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "sample_size": 1000,
                "include_all_schemas": True,
                "exclude_schemas": ["pg_catalog", "information_schema"]
            },
            "operational_settings": {
                "connection_timeout_seconds": 30,
                "query_timeout_seconds": 600,
                "concurrent_tables": 5,
                "retry_attempts": 3
            }
        }
    },
    {
        "integrationType": "aws-documentdb",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "sample_size": 1000,
                "include_all_collections": True,
                "exclude_collections": []
            },
            "operational_settings": {
                "connection_timeout_seconds": 30,
                "query_timeout_seconds": 300,
                "concurrent_collections": 3,
                "retry_attempts": 3
            }
        }
    },
    # Compute
    {
        "integrationType": "aws-ec2",
        "configVersion": "v2.0",
        "defaultConfig": {
            "customer_settings": {
                "scan_enabled": True,
                "scan_frequency": "weekly",
                "scan_volumes": True,
                "max_volume_size_gb": 500
            },
            "operational_settings": {
                "concurrent_instances": 5,
                "snapshot_timeout_seconds": 3600,
                "retry_attempts": 3
            }
        }
    },
    # Note: AI/ML services (Bedrock, SageMaker) are not included here
    # They only have Assets collection enabled, not Data Discovery scanning
]


def get_table_name(environment: str) -> str:
    """Get the DynamoDB table name for the given environment"""
    # Table naming follows CDK convention: just the resource name (no env prefix)
    return "master-integrations"


def get_configs_table_name(environment: str) -> str:
    """Get the DynamoDB configs table name for the given environment"""
    return "master-integration-configs"


def build_service_item(service_config: Dict[str, Any], provider: str = "aws") -> Dict[str, Any]:
    """Build a DynamoDB item for a service"""
    service_name = service_config["service"]
    now = datetime.now(timezone.utc).isoformat()

    # Determine feature flags based on requirements
    cspm_enabled = True  # All services have CSPM per requirements
    assets_enabled = service_name in ASSETS_ENABLED_SERVICES
    data_discovery_enabled = service_name in DATA_DISCOVERY_ENABLED_SERVICES

    return {
        "pk": f"{provider}#{service_name}",
        "provider": provider,
        "service": service_name,
        "displayName": service_config["displayName"],
        "description": service_config.get("description", ""),
        "category": service_config["category"],

        # Feature flags as strings for GSI compatibility
        "cspmEnabled": "true" if cspm_enabled else "false",
        "assetsEnabled": "true" if assets_enabled else "false",
        "dataDiscoveryEnabled": "true" if data_discovery_enabled else "false",

        # Detailed features map for API responses
        "features": {
            "cspm": {
                "enabled": cspm_enabled,
                "description": "Cloud Security Posture Management checks"
            },
            "assets": {
                "enabled": assets_enabled,
                "description": "Asset inventory tracking"
            },
            "dataDiscovery": {
                "enabled": data_discovery_enabled,
                "description": "Data discovery and classification"
            }
        },

        # Collector info (maps to collector_registry.py)
        "collectorName": service_name,

        # Timestamps
        "createdAt": now,
        "updatedAt": now,
        "updatedBy": "system"
    }


def seed_services(environment: str, dry_run: bool = False) -> Dict[str, int]:
    """Seed all AWS and M365 services to the master-integrations table"""
    table_name = get_table_name(environment)

    logger.info(f"{'[DRY RUN] ' if dry_run else ''}Seeding services to table: {table_name}")

    if not dry_run:
        dynamodb = boto3.resource('dynamodb')
        table = dynamodb.Table(table_name)

    stats = {"processed": 0, "written": 0, "errors": 0}
    items_by_category: Dict[str, int] = {}
    items_by_provider: Dict[str, int] = {}

    # Process all services (AWS + M365)
    all_services = [
        (service_config, "aws") for service_config in AWS_SERVICES
    ] + [
        (service_config, "m365") for service_config in M365_SERVICES
    ]

    for service_config, provider in all_services:
        stats["processed"] += 1
        item = build_service_item(service_config, provider)

        # Track by category and provider
        category = service_config["category"]
        items_by_category[category] = items_by_category.get(category, 0) + 1
        items_by_provider[provider] = items_by_provider.get(provider, 0) + 1

        if dry_run:
            features = []
            if item["cspmEnabled"] == "true":
                features.append("CSPM")
            if item["assetsEnabled"] == "true":
                features.append("Assets")
            if item["dataDiscoveryEnabled"] == "true":
                features.append("DataDiscovery")
            logger.info(f"  [DRY RUN] {item['pk']}: {', '.join(features)}")
            stats["written"] += 1
        else:
            try:
                table.put_item(Item=item)
                logger.info(f"  Written: {item['pk']}")
                stats["written"] += 1
            except Exception as e:
                logger.error(f"  Error writing {item['pk']}: {e}")
                stats["errors"] += 1

    # Print summary
    print("\n" + "=" * 80)
    print("Seeding Summary")
    print("=" * 80)
    print(f"Total services: {stats['processed']}")
    print(f"Written: {stats['written']}")
    print(f"Errors: {stats['errors']}")
    print("\nBy provider:")
    for provider, count in sorted(items_by_provider.items()):
        print(f"  {provider}: {count}")
    print("\nBy category:")
    for category, count in sorted(items_by_category.items()):
        print(f"  {category}: {count}")

    # Print feature summary
    assets_services = sorted(ASSETS_ENABLED_SERVICES)
    data_discovery_services = sorted(DATA_DISCOVERY_ENABLED_SERVICES)
    print("\nFeature coverage:")
    print(f"  CSPM: {stats['processed']} services (all)")
    print(f"  Assets: {len(assets_services)} services ({', '.join(assets_services)})")
    print(f"  Data Discovery: {len(data_discovery_services)} services ({', '.join(data_discovery_services)})")
    print("=" * 80)

    return stats


def verify_table(environment: str):
    """Verify seeded data in the master-integrations table"""
    table_name = get_table_name(environment)
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table(table_name)

    print(f"Verifying master-integrations table: {table_name}")
    print("=" * 80)

    try:
        # Scan all items
        response = table.scan()
        items = response.get('Items', [])

        # Handle pagination
        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            items.extend(response.get('Items', []))

        print(f"Total items: {len(items)}")

        # Count by provider and category
        by_provider: Dict[str, int] = {}
        by_category: Dict[str, int] = {}
        cspm_count = 0
        assets_count = 0
        data_discovery_count = 0

        for item in items:
            provider = item.get('provider', 'unknown')
            category = item.get('category', 'unknown')
            by_provider[provider] = by_provider.get(provider, 0) + 1
            by_category[category] = by_category.get(category, 0) + 1

            if item.get('cspmEnabled') == 'true':
                cspm_count += 1
            if item.get('assetsEnabled') == 'true':
                assets_count += 1
            if item.get('dataDiscoveryEnabled') == 'true':
                data_discovery_count += 1

        print("\nBy provider:")
        for provider, count in sorted(by_provider.items()):
            print(f"  {provider}: {count}")

        print("\nBy category:")
        for category, count in sorted(by_category.items()):
            print(f"  {category}: {count}")

        print("\nFeature coverage:")
        print(f"  CSPM enabled: {cspm_count}")
        print(f"  Assets enabled: {assets_count}")
        print(f"  Data Discovery enabled: {data_discovery_count}")

        # List services with each feature
        print("\nServices with Assets feature:")
        for item in sorted(items, key=lambda x: x.get('pk', '')):
            if item.get('assetsEnabled') == 'true':
                print(f"  - [{item.get('provider')}] {item.get('service')}: {item.get('displayName')}")

        print("\nServices with Data Discovery feature:")
        for item in sorted(items, key=lambda x: x.get('pk', '')):
            if item.get('dataDiscoveryEnabled') == 'true':
                print(f"  - [{item.get('provider')}] {item.get('service')}: {item.get('displayName')}")

    except Exception as e:
        print(f"Error verifying table: {e}")

    print("=" * 80)


def seed_integration_configs(environment: str, dry_run: bool = False) -> Dict[str, int]:
    """Seed default scan configuration settings to the master-integration-configs table"""
    table_name = get_configs_table_name(environment)

    logger.info(f"{'[DRY RUN] ' if dry_run else ''}Seeding integration configs to table: {table_name}")

    if not dry_run:
        dynamodb = boto3.resource('dynamodb')
        table = dynamodb.Table(table_name)

    stats = {"processed": 0, "written": 0, "errors": 0}
    now = datetime.now(timezone.utc).isoformat()

    for config in INTEGRATION_CONFIGS:
        stats["processed"] += 1

        item = {
            "integrationType": config["integrationType"],
            "configVersion": config["configVersion"],
            "defaultConfig": config["defaultConfig"],
            "createdAt": now,
            "updatedAt": now,
            "updatedBy": "system"
        }

        if dry_run:
            logger.info(f"  [DRY RUN] {item['integrationType']} (version: {item['configVersion']})")
            stats["written"] += 1
        else:
            try:
                table.put_item(Item=item)
                logger.info(f"  Written: {item['integrationType']} (version: {item['configVersion']})")
                stats["written"] += 1
            except Exception as e:
                logger.error(f"  Error writing {item['integrationType']}: {e}")
                stats["errors"] += 1

    # Print summary
    print("\n" + "=" * 80)
    print("Integration Configs Seeding Summary")
    print("=" * 80)
    print(f"Total configs: {stats['processed']}")
    print(f"Written: {stats['written']}")
    print(f"Errors: {stats['errors']}")

    # Group by category
    storage_configs = [c for c in INTEGRATION_CONFIGS if c["integrationType"].startswith(("aws-s3", "aws-efs", "aws-fsx"))]
    database_configs = [c for c in INTEGRATION_CONFIGS if c["integrationType"].startswith(("aws-dynamodb", "aws-rds", "aws-neptune", "aws-redshift", "aws-documentdb"))]
    compute_configs = [c for c in INTEGRATION_CONFIGS if c["integrationType"].startswith("aws-ec2")]

    print("\nBy category:")
    print(f"  Storage: {len(storage_configs)} configs")
    print(f"  Database: {len(database_configs)} configs")
    print(f"  Compute: {len(compute_configs)} configs")
    print("=" * 80)

    return stats


def verify_integration_configs(environment: str):
    """Verify seeded data in the master-integration-configs table"""
    table_name = get_configs_table_name(environment)
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table(table_name)

    print(f"Verifying master-integration-configs table: {table_name}")
    print("=" * 80)

    try:
        # Scan all items
        response = table.scan()
        items = response.get('Items', [])

        # Handle pagination
        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            items.extend(response.get('Items', []))

        print(f"Total configs: {len(items)}")

        # List all configs
        print("\nConfigs by integration type:")
        for item in sorted(items, key=lambda x: x.get('integrationType', '')):
            integration_type = item.get('integrationType', 'unknown')
            config_version = item.get('configVersion', 'unknown')
            default_config = item.get('defaultConfig', {})

            # Summarize config settings
            customer_settings = default_config.get('customer_settings', {})
            operational_settings = default_config.get('operational_settings', {})

            scan_enabled = customer_settings.get('scan_enabled', 'N/A')
            scan_frequency = customer_settings.get('scan_frequency', 'N/A')

            print(f"\n  {integration_type} (v{config_version}):")
            print(f"    scan_enabled: {scan_enabled}")
            print(f"    scan_frequency: {scan_frequency}")
            print(f"    customer_settings keys: {list(customer_settings.keys())}")
            print(f"    operational_settings keys: {list(operational_settings.keys())}")

        # Check for expected vs actual
        expected_types = {c["integrationType"] for c in INTEGRATION_CONFIGS}
        actual_types = {item.get('integrationType') for item in items}

        missing = expected_types - actual_types
        extra = actual_types - expected_types

        if missing:
            print(f"\n⚠️  Missing configs (defined but not in table): {sorted(missing)}")
        if extra:
            print(f"\nℹ️  Extra configs (in table but not defined): {sorted(extra)}")
        if not missing and not extra:
            print("\n✅ All expected configs present")

    except Exception as e:
        print(f"Error verifying configs table: {e}")

    print("=" * 80)


def main():
    parser = argparse.ArgumentParser(
        description='Seed master integrations and integration configs tables',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Seed both tables:
    python seed-master-integrations.py --environment dev

  Seed only service catalog (master-integrations):
    python seed-master-integrations.py --environment dev --services-only

  Seed only scan configs (master-integration-configs):
    python seed-master-integrations.py --environment dev --configs-only

  Verify both tables:
    python seed-master-integrations.py --environment dev --verify --verify-configs

  Dry run (preview changes):
    python seed-master-integrations.py --environment dev --dry-run
        """
    )
    parser.add_argument('--environment', '-e', required=True,
                       help='Environment to seed (e.g. dev, dev2, staging, prod)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Print actions without writing to DynamoDB')
    parser.add_argument('--verify', action='store_true',
                       help='Verify master-integrations table data')
    parser.add_argument('--verify-configs', action='store_true',
                       help='Verify master-integration-configs table data')
    parser.add_argument('--services-only', action='store_true',
                       help='Only seed the master-integrations table (service catalog)')
    parser.add_argument('--configs-only', action='store_true',
                       help='Only seed the master-integration-configs table (scan settings)')

    args = parser.parse_args()

    # Verification mode
    if args.verify or args.verify_configs:
        if args.verify:
            verify_table(args.environment)
        if args.verify_configs:
            verify_integration_configs(args.environment)
        return

    # Determine what to seed
    seed_services_flag = not args.configs_only  # Seed services unless --configs-only
    seed_configs_flag = not args.services_only  # Seed configs unless --services-only

    # If both --services-only and --configs-only specified, seed nothing (user error)
    if args.services_only and args.configs_only:
        print("Error: Cannot specify both --services-only and --configs-only")
        return

    total_errors = 0

    # Seed master-integrations (service catalog)
    if seed_services_flag:
        stats = seed_services(args.environment, args.dry_run)
        total_errors += stats.get('errors', 0)

    # Seed master-integration-configs (default scan settings)
    if seed_configs_flag:
        stats = seed_integration_configs(args.environment, args.dry_run)
        total_errors += stats.get('errors', 0)

    if not args.dry_run and total_errors == 0:
        print("\nRun with --verify and/or --verify-configs to check seeded data")


if __name__ == '__main__':
    main()
