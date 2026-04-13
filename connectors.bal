// connectors.bal

//public final Connector[] & readonly ALL_CONNECTORS = [
    // ── Twilio ──────────────────────────────────────────────────────────────
    // ballerinax/twilio  →  Twilio REST API
    //{name: "Twilio",                        docsUrl: "https://www.twilio.com/docs/usage/api",                                                                          targetTitle: ()},

    // ── Google Sheets ────────────────────────────────────────────────────────
    // ballerinax/googleapis.sheets  →  Google Sheets API v4
    //{name: "GoogleAPIs Sheets",             docsUrl: "https://developers.google.com/sheets/api/reference/rest",                                                        targetTitle: ()},

    // ── Twitter ──────────────────────────────────────────────────────────────
    // ballerinax/twitter  →  Twitter v2 API (OpenAPI spec lives in xdevplatform)
    //{name: "Twitter",                       docsUrl: "https://github.com/xdevplatform",                                                                                targetTitle: ()},

    // ── Java JDBC ────────────────────────────────────────────────────────────
    // ballerinax/java.jdbc  →  Jakarta EE JDBC specification (no vendor OpenAPI;
    // JDBC is a Java API, not a REST API with an OpenAPI spec)
    //{name: "Java JDBC",                     docsUrl: "https://docs.oracle.com/en/java/jakarta/specifications/jdbc/",                                                   targetTitle: ()},

    // ── Salesforce ───────────────────────────────────────────────────────────
    // ballerinax/salesforce  →  Salesforce REST API
    //{name: "Salesforce",                    docsUrl: "https://developer.salesforce.com/docs/apis",                                                                     targetTitle: ()},

    // ── MySQL ────────────────────────────────────────────────────────────────
    // ballerinax/mysql  →  MySQL Connector/J (JDBC driver; SQL protocol, no OpenAPI)
    //{name: "MySQL",                         docsUrl: "https://dev.mysql.com/doc/connector-j/en/",                                                                      targetTitle: ()},

    // ── Kafka ────────────────────────────────────────────────────────────────
    // ballerinax/kafka  →  Apache Kafka (binary protocol, not REST/OpenAPI)
    //{name: "Kafka",                         docsUrl: "https://kafka.apache.org/documentation/",                                                                        targetTitle: ()},

    // ── Redis ────────────────────────────────────────────────────────────────
    // ballerinax/redis  →  Redis command reference (RESP protocol, no OpenAPI)
    //{name: "Redis",                         docsUrl: "https://redis.io/docs/latest/commands/",                                                                         targetTitle: ()},

    // ── PostgreSQL ───────────────────────────────────────────────────────────
    // ballerinax/postgresql  →  PostgreSQL docs (JDBC/SQL protocol, no OpenAPI)
    //{name: "PostgreSQL",                    docsUrl: "https://www.postgresql.org/docs/current/",                                                                       targetTitle: ()},

    // ── SAP ──────────────────────────────────────────────────────────────────
    // ballerinax/sap  →  SAP Business Accelerator Hub (OpenAPI specs per service)
    //{name: "SAP",                           docsUrl: "https://api.sap.com/",                                                                                           targetTitle: ()},

    // ── MSSQL ────────────────────────────────────────────────────────────────
    // ballerinax/mssql  →  Microsoft JDBC Driver for SQL Server
    //{name: "MSSQL",                         docsUrl: "https://learn.microsoft.com/en-us/sql/connect/jdbc/microsoft-jdbc-driver-for-sql-server",                        targetTitle: ()},

    // ── Confluent Schema Registry ────────────────────────────────────────────
    // ballerinax/confluent.schemaregistry  →  Schema Registry REST API reference
    //{name: "Confluent Schema Registry",     docsUrl: "https://github.com/confluentinc/schema-registry",                                    targetTitle: ()}

    // ── CDC (Change Data Capture) ────────────────────────────────────────────
    // ballerinax/cdc  →  Debezium documentation (the underlying CDC engine)
    //{name: "CDC",                           docsUrl: "https://debezium.io/documentation/reference/stable/",                                                            targetTitle: ()},

    // ── Confluent Avro SerDes ────────────────────────────────────────────────
    // ballerinax/confluent.cavroserdes  →  Avro SerDes for Confluent Schema Registry
    //{name: "Confluent Avro SerDes",         docsUrl: "https://docs.confluent.io/platform/current/schema-registry/fundamentals/serdes-develop/serdes-avro.html",        targetTitle: ()},

    // ── OpenAI Chat ──────────────────────────────────────────────────────────
    // ballerinax/openai.chat  →  OpenAI Chat Completions API reference
    //{name: "OpenAI Chat",                   docsUrl: "https://platform.openai.com/docs/api-reference/chat",                                                            targetTitle: ()},

    // ── RabbitMQ ─────────────────────────────────────────────────────────────
    // ballerinax/rabbitmq  →  RabbitMQ Management HTTP API
    //{name: "RabbitMQ",                      docsUrl: "https://www.rabbitmq.com/docs/management",                                                                       targetTitle: ()}

    // ── Snowflake ────────────────────────────────────────────────────────────
    // ballerinax/snowflake  →  Snowflake SQL REST API reference
    //{name: "Snowflake",                     docsUrl: "https://docs.snowflake.com/en/developer-guide/sql-api/reference",                                                targetTitle: ()},

    // ── Oracle DB ────────────────────────────────────────────────────────────
    // ballerinax/oracledb  →  Oracle REST Data Services (ORDS) developer guide
    //{name: "Oracle DB",                     docsUrl: "https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/latest/orddg/index.html",                   targetTitle: ()},

    // ── MongoDB ──────────────────────────────────────────────────────────────
    // ballerinax/mongodb  →  MongoDB Atlas Data API resources
    //{name: "MongoDB",                       docsUrl: "https://www.mongodb.com/docs/atlas/api/data-api-resources/",                                                     targetTitle: ()},

    // ── Azure Storage Service ────────────────────────────────────────────────
    // ballerinax/azure_storage_service  →  Azure Storage REST API reference
    //{name: "Azure Storage Service",         docsUrl: "https://learn.microsoft.com/en-us/rest/api/storageservices/",                                                    targetTitle: ()},

    // ── AI OpenAI ────────────────────────────────────────────────────────────
    // ballerinax/ai.openai  →  OpenAI platform API reference
    //{name: "AI OpenAI",                     docsUrl: "https://platform.openai.com/docs/api-reference/introduction",                                                    targetTitle: ()},

    // ── AI Pinecone ──────────────────────────────────────────────────────────
    // ballerinax/ai.pinecone  →  Pinecone Vector Database API reference
    //{name: "AI Pinecone",                   docsUrl: "https://docs.pinecone.io/reference/api/introduction",                                                            targetTitle: ()},

    // ── FHIR ─────────────────────────────────────────────────────────────────
    // ballerinax/health.clients.fhir  →  HL7 FHIR R4 RESTful API specification
    //{name: "FHIR",                          docsUrl: "https://hl7.org/fhir/R4/http.html",                                                                              targetTitle: ()}

    // ── AI Anthropic ─────────────────────────────────────────────────────────
    // ballerinax/ai.anthropic  →  Anthropic Messages API
    //{name: "AI Anthropic",                  docsUrl: "https://docs.anthropic.com/en/api/getting-started",                                                              targetTitle: ()},

    // ── AI Azure ─────────────────────────────────────────────────────────────
    // ballerinax/ai.azure  →  Azure OpenAI Service REST API reference
    //{name: "AI Azure",                      docsUrl: "https://learn.microsoft.com/en-us/azure/ai-services/openai/reference",                                           targetTitle: ()},

    // ── AI Ollama ────────────────────────────────────────────────────────────
    // ballerinax/ai.ollama  →  Ollama REST API docs (GitHub)
    //{name: "AI Ollama",                     docsUrl: "https://github.com/ollama/ollama/blob/main/docs/api.md",                                                         targetTitle: ()},

    // ── AI Mistral ───────────────────────────────────────────────────────────
    // ballerinax/ai.mistral  →  Mistral AI API reference
    //{name: "AI Mistral",                    docsUrl: "https://docs.mistral.ai/api/",                                                                                   targetTitle: ()},

    // ── DeepSeek AI Connector ────────────────────────────────────────────────
    // ballerinax/ai.deepseek  →  DeepSeek API reference
    //{name: "DeepSeek AI Connector",         docsUrl: "https://api-docs.deepseek.com/",                                                                                 targetTitle: ()},

    // ── Stripe ───────────────────────────────────────────────────────────────
    // ballerinax/stripe  →  Stripe API reference
    //{name: "Stripe",                        docsUrl: "https://github.com/stripe/openapi",                                                                                    targetTitle: ()},

    // ── Slack ────────────────────────────────────────────────────────────────
    // ballerinax/slack  →  Slack Web API (OpenAPI spec in slackapi/slack-api-specs)
    //{name: "Slack",                         docsUrl: "https://github.com/slackapi/slack-api-specs",                                                                    targetTitle: ("Slack Web API")}
//];
// connectors.bal
public final Connector[] & readonly ALL_CONNECTORS = [
    // ✅ Official spec in mistralai/platform-docs-public GitHub repo
    //{name: "Mistral",                docsUrl: "https://github.com/mistralai/platform-docs-public",                                                                              targetTitle: ()},

    // ⚠️  NATS uses a binary/pub-sub protocol — no REST OpenAPI spec exists.
    //     Best available: JSON Schema registry at nats.io/schemas/
    //     Using the official NATS docs page as the closest reference.
    //{name: "NATS",                   docsUrl: "https://docs.nats.io/reference/reference-protocols/nats_api_reference",                                                                                            targetTitle: ()},

    // ✅ Official spec in AWS SDK repo (converted from Smithy/JSON to OpenAPI by APIs-guru/aws2openapi)
    //    SNS uses a query-over-HTTP protocol; best available OpenAPI spec is via APIs-guru
    //{name: "AWS SNS",                docsUrl: "https://docs.aws.amazon.com/sns/latest/api/welcome.html",                                               targetTitle: ()},

    // ✅ Official spec via APIs-guru (converted from AWS SDK Smithy model)
    //{name: "AWS SQS",                docsUrl: "https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-working-with-apis.html",                                               targetTitle: ()},

    // ✅ Official Weaviate OpenAPI spec (schema.json in the main repo)
    //{name: "AI Weaviate",            docsUrl: "https://docs.weaviate.io/weaviate/model-providers/openai",                                                                               targetTitle: ()},

    // ✅ OneDrive is part of Microsoft Graph API — official OpenAPI spec from msgraph-metadata
    //{name: "Microsoft OneDrive",     docsUrl: "https://learn.microsoft.com/en-us/onedrive/developer/rest-api/getting-started/?view=odsp-graph-online",                                                              targetTitle: ()},

    // ✅ Official Trello OpenAPI spec published by Atlassian
    {name: "Trello",                 docsUrl: "https://developer.atlassian.com/cloud/trello/rest/api-group-actions/",                                                                                                     targetTitle: ()},

    // ✅ Official spec via APIs-guru (converted from AWS SDK Smithy model — Redshift Data API)
    {name: "AWS Redshift",           docsUrl: "https://docs.aws.amazon.com/redshift/latest/mgmt/data-api.html",                                     targetTitle: ()},

    // ✅ Official Solace PubSub+ Cloud Mission Control OpenAPI spec
    {name: "Solace",                 docsUrl: "https://api.solace.dev/cloud/page/openapi-specifications",                                                                                                         targetTitle: ()},

    // ✅ Official Asana OpenAPI spec from the Asana/openapi GitHub repo
    {name: "Asana",                  docsUrl: "https://github.com/Asana/openapi",                                                                                       targetTitle: ()},

    // ⚠️  SCIM 2.0 is an IETF protocol standard (RFC 7643/7644), not a single vendor's API.
    //     No single canonical OpenAPI spec — using Okta's SCIM 2.0 spec as the most widely
    //     adopted reference implementation.
    {name: "SCIM",                   docsUrl: "https://developer.okta.com/docs/api/openapi/okta-scim/guides/scim-20",                                                                                             targetTitle: ()},

    // ✅ Official PayPal Orders v2 OpenAPI spec from paypal/paypal-rest-api-specifications
    {name: "PayPal Orders",          docsUrl: "https://developer.paypal.com/docs/api/orders/v2/",                                                     targetTitle: ()},

    // ⚠️  IBM MQ REST API spec is served at runtime by the MQ web server (Liberty/WLP).
    //     No static publicly downloadable file — using the official IBM Cloud docs as reference.
    {name: "IBM MQ",                 docsUrl: "https://www.ibm.com/docs/en/ibm-mq/latest?topic=api-rest-reference",                                                                                               targetTitle: ()},

    // ✅ Official spec via APIs-guru (converted from AWS SDK Smithy model)
    {name: "AWS Secret Manager",     docsUrl: "https://aws.amazon.com/secrets-manager/",                                    targetTitle: ()}
];
