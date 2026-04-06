// connectors.bal

public final Connector[] & readonly ALL_CONNECTORS = [
    // Jira: Atlassian CDN serves the spec directly
    {name: "Jira",                       docsUrl: "https://developer.atlassian.com/cloud/jira/platform/rest/v3/",                               targetTitle: ()},

    // Mailchimp Marketing: official spec is spec/marketing.json in the codegen repo
    // The docs page (mailchimp.com/developer/marketing/api/) lists the spec link deep
    // in the page body (after ~200KB of endpoint docs). Pointing directly at the
    // codegen repo avoids the page-depth problem entirely.
    {name: "Mailchimp Marketing",        docsUrl: "https://github.com/mailchimp/mailchimp-client-lib-codegen",                                  targetTitle: ()},

    // Mailchimp Transactional: official spec is spec/transactional.json in the same codegen repo
    // Same repo as Marketing — both Marketing and Transactional specs live in spec/
    {name: "Mailchimp Transactional",    docsUrl: "https://github.com/mailchimp/mailchimp-client-lib-codegen",                                  targetTitle: ()},

    // Microsoft OneDrive: part of Microsoft Graph — spec is in microsoftgraph/msgraph-metadata
    {name: "Microsoft OneDrive",         docsUrl: "https://learn.microsoft.com/en-us/onedrive/developer/rest-api/",                             targetTitle: ()},

    // OpenAI: the openai/openai-openapi repo uses date-based branch tags (e.g. 2025-03-21)
    // The master branch only has README — spec lives on the dated branches
    {name: "OpenAI",                     docsUrl: "https://github.com/openai/openai-openapi",                                                   targetTitle: ()},

    // PayPal: all specs are in paypal/paypal-rest-api-specifications/openapi/
    {name: "PayPal Invoices",            docsUrl: "https://developer.paypal.com/docs/api/invoicing/v2/",                                        targetTitle: ()},
    {name: "PayPal Orders",              docsUrl: "https://developer.paypal.com/docs/api/orders/v2/",                                           targetTitle: ()},
    {name: "PayPal Payments",            docsUrl: "https://developer.paypal.com/docs/api/payments/v2/",                                         targetTitle: ()},
    {name: "PayPal Subscriptions",       docsUrl: "https://developer.paypal.com/docs/api/subscriptions/v1/",                                    targetTitle: ()},

    // Salesforce Marketing Cloud: no official docs page with spec link.
    // The only known spec is in the mcsdk-automation-framework-core repo.
    {name: "Salesforce Marketing Cloud", docsUrl: "https://github.com/salesforce-marketingcloud/mcsdk-automation-framework-core",               targetTitle: ()}
];
