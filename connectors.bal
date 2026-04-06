// connectors.bal

public final Connector[] & readonly ALL_CONNECTORS = [
    // Jira: Atlassian CDN serves the spec directly — stable URL
    {name: "Jira",                       docsUrl: "https://developer.atlassian.com/cloud/jira/platform/rest/v3/",                               targetTitle: ()},

    // Mailchimp Marketing: spec link is visible on the API reference page
    // The page shows "v. 3.0.91 → github.com/mailchimp/mailchimp-client-lib-codegen/blob/main/spec/marketing.json"
    {name: "Mailchimp Marketing",        docsUrl: "https://mailchimp.com/developer/marketing/api/",                                             targetTitle: ()},

    // Mailchimp Transactional: no official OpenAPI — only available via APIs-guru (mandrillapp.com)
    {name: "Mailchimp Transactional",    docsUrl: "https://mailchimp.com/developer/transactional/api/",                                         targetTitle: ()},

    // Microsoft OneDrive: part of Microsoft Graph — spec is in microsoftgraph/msgraph-metadata
    {name: "Microsoft OneDrive",         docsUrl: "https://learn.microsoft.com/en-us/onedrive/developer/rest-api/",                             targetTitle: ()},

    // OpenAI: the openai/openai-openapi repo uses date-based branch tags (e.g. 2025-03-21)
    // The master branch no longer has the spec inline — it lives on the dated branches
    {name: "OpenAI",                     docsUrl: "https://github.com/openai/openai-openapi",                                                   targetTitle: ()},

    // PayPal: all specs are in paypal/paypal-rest-api-specifications/openapi/
    {name: "PayPal Invoices",            docsUrl: "https://developer.paypal.com/docs/api/invoicing/v2/",                                        targetTitle: ()},
    {name: "PayPal Orders",              docsUrl: "https://developer.paypal.com/docs/api/orders/v2/",                                           targetTitle: ()},
    {name: "PayPal Payments",            docsUrl: "https://developer.paypal.com/docs/api/payments/v2/",                                         targetTitle: ()},
    {name: "PayPal Subscriptions",       docsUrl: "https://developer.paypal.com/docs/api/subscriptions/v1/",                                    targetTitle: ()},

    // Salesforce Marketing Cloud: no public OpenAPI spec exists.
    // The official docs are HTML-only with no downloadable spec file.
    // The only known source is the mcsdk-automation repo which has a partial swagger 2.0 spec.
    {name: "Salesforce Marketing Cloud", docsUrl: "https://github.com/salesforce-marketingcloud/mcsdk-automation-framework-core",               targetTitle: ()}
];
