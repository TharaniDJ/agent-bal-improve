// connectors.bal
// Full connector registry — 71 connectors.
//
// docsUrl = the official API documentation page for that connector.
//           This is what the agent fetches to discover the spec URL.
//
// targetTitle = only set for multi-spec pages (Candid) where one docs URL
//               hosts several different specs. The LLM strategy uses this
//               to pick the right one.
//
// Notes on challenging connectors:
//   HubSpot     — specs come from the HubSpot catalog API, not the docs page.
//                 known_patterns.bal maps each sub-module to its catalog URL.
//   Candid       — three specs from one page; targetTitle selects the right one.
//   Dayforce     — no public OpenAPI spec found; LLM fallback may still find one.
//   SAP S/4HANA  — specs behind SAP API Hub, may require authentication.
//   Guidewire    — developer portal may require login; LLM tries anyway.

public final Connector[] & readonly ALL_CONNECTORS = [

    // ── Project Management ────────────────────────────────────────────────────
    {name: "Asana",  docsUrl: "https://developers.asana.com/reference/rest-api-reference", targetTitle: ()},
    {name: "Jira",   docsUrl: "https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/", targetTitle: ()},
    {name: "Trello", docsUrl: "https://developer.atlassian.com/cloud/trello/rest/api-group-actions/", targetTitle: ()},

    // ── Communication ─────────────────────────────────────────────────────────
    {name: "Slack",          docsUrl: "https://api.slack.com/web", targetTitle: ()},
    {name: "Discord",        docsUrl: "https://discord.com/developers/docs/reference", targetTitle: ()},
    {name: "Twilio",         docsUrl: "https://www.twilio.com/docs/openapi", targetTitle: ()},
    {name: "Twitter",        docsUrl: "https://developer.twitter.com/en/docs/twitter-api", targetTitle: ()},

    // ── Source Control ────────────────────────────────────────────────────────
    {name: "GitHub", docsUrl: "https://docs.github.com/en/rest", targetTitle: ()},

    // ── Document Signing ──────────────────────────────────────────────────────
    {name: "DocuSign Admin API", docsUrl: "https://developers.docusign.com/docs/admin-api/",      targetTitle: ()},
    {name: "DocuSign Click API", docsUrl: "https://developers.docusign.com/docs/click-api/",      targetTitle: ()},
    {name: "DocuSign eSign API", docsUrl: "https://developers.docusign.com/docs/esign-rest-api/", targetTitle: ()},

    // ── Nonprofit Data — one docs URL, three specs ────────────────────────────
    {name: "Candid CharityCheckPdf", docsUrl: "https://developer.candid.org/reference/openapi", targetTitle: "CharityCheckPdf"},
    {name: "Candid Essentials",      docsUrl: "https://developer.candid.org/reference/openapi", targetTitle: "Essentials"},
    {name: "Candid Premier",         docsUrl: "https://developer.candid.org/reference/openapi", targetTitle: "Premier API"},

    // ── HR / Workforce ────────────────────────────────────────────────────────
    // NOTE: Dayforce has no confirmed public OpenAPI spec; LLM strategies will try.
    {name: "Dayforce", docsUrl: "https://developers.dayforce.com/Build/Home.aspx", targetTitle: ()},

    // ── Cloud ─────────────────────────────────────────────────────────────────
    {name: "Elastic Cloud", docsUrl: "https://www.elastic.co/docs/api/doc/cloud", targetTitle: ()},

    // ── Google ────────────────────────────────────────────────────────────────
    {name: "Google Calendar", docsUrl: "https://developers.google.com/calendar/api/v3/reference", targetTitle: ()},
    {name: "Google Gmail",    docsUrl: "https://developers.google.com/gmail/api/reference/rest",  targetTitle: ()},

    // ── Insurance ─────────────────────────────────────────────────────────────
    // NOTE: Guidewire developer portal may require login.
    {name: "Guidewire InsuranceNow", docsUrl: "https://developer.guidewire.com/insurancenow/reference", targetTitle: ()},

    // ── HubSpot CRM ───────────────────────────────────────────────────────────


    {name: "HubSpot CRM Contacts",                    docsUrl: "https://developers.hubspot.com/docs/api/crm/contacts",                            targetTitle: ()},
    {name: "HubSpot CRM Companies",                   docsUrl: "https://developers.hubspot.com/docs/api/crm/companies",                           targetTitle: ()},
    {name: "HubSpot CRM Deals",                       docsUrl: "https://developers.hubspot.com/docs/api/crm/deals",                               targetTitle: ()},
    {name: "HubSpot CRM Associations",                docsUrl: "https://developers.hubspot.com/docs/api/crm/associations",                        targetTitle: ()},
    {name: "HubSpot CRM Associations Schema",         docsUrl: "https://developers.hubspot.com/docs/api/crm/associations",                        targetTitle: ()},
    {name: "HubSpot CRM Owners",                      docsUrl: "https://developers.hubspot.com/docs/api/crm/owners",                              targetTitle: ()},
    {name: "HubSpot CRM Pipelines",                   docsUrl: "https://developers.hubspot.com/docs/api/crm/pipelines",                           targetTitle: ()},
    {name: "HubSpot CRM Properties",                  docsUrl: "https://developers.hubspot.com/docs/api/crm/properties",                          targetTitle: ()},
    {name: "HubSpot CRM Object Tickets",              docsUrl: "https://developers.hubspot.com/docs/api/crm/tickets",                             targetTitle: ()},
    {name: "HubSpot CRM Object Products",             docsUrl: "https://developers.hubspot.com/docs/api/crm/products",                            targetTitle: ()},
    {name: "HubSpot CRM Object Line Items",           docsUrl: "https://developers.hubspot.com/docs/api/crm/line-items",                          targetTitle: ()},
    {name: "HubSpot CRM Object Feedback",             docsUrl: "https://developers.hubspot.com/docs/api/crm/feedback-submissions",                targetTitle: ()},
    {name: "HubSpot CRM Object Leads",                docsUrl: "https://developers.hubspot.com/docs/api/crm/leads",                               targetTitle: ()},
    {name: "HubSpot CRM Object Schemas",              docsUrl: "https://developers.hubspot.com/docs/api/crm/crm-custom-objects",                  targetTitle: ()},
    {name: "HubSpot CRM Import",                      docsUrl: "https://developers.hubspot.com/docs/api/crm/imports",                             targetTitle: ()},
    {name: "HubSpot CRM Lists",                       docsUrl: "https://developers.hubspot.com/docs/api/crm/lists",                               targetTitle: ()},
    {name: "HubSpot CRM Commerce Carts",              docsUrl: "https://developers.hubspot.com/docs/api/crm/carts",                               targetTitle: ()},
    {name: "HubSpot CRM Commerce Discounts",          docsUrl: "https://developers.hubspot.com/docs/api/crm/discounts",                           targetTitle: ()},
    {name: "HubSpot CRM Commerce Orders",             docsUrl: "https://developers.hubspot.com/docs/api/crm/orders",                              targetTitle: ()},
    {name: "HubSpot CRM Commerce Quotes",             docsUrl: "https://developers.hubspot.com/docs/api/crm/quotes",                              targetTitle: ()},
    {name: "HubSpot CRM Commerce Taxes",              docsUrl: "https://developers.hubspot.com/docs/api/crm/taxes",                               targetTitle: ()},
    {name: "HubSpot CRM Engagement Meeting",          docsUrl: "https://developers.hubspot.com/docs/api/crm/meetings",                            targetTitle: ()},
    {name: "HubSpot CRM Engagement Notes",            docsUrl: "https://developers.hubspot.com/docs/api/crm/notes",                               targetTitle: ()},
    {name: "HubSpot CRM Engagements Calls",           docsUrl: "https://developers.hubspot.com/docs/api/crm/calls",                               targetTitle: ()},
    {name: "HubSpot CRM Engagements Communications",  docsUrl: "https://developers.hubspot.com/docs/api/crm/communications",                      targetTitle: ()},
    {name: "HubSpot CRM Engagements Email",           docsUrl: "https://developers.hubspot.com/docs/api/crm/email",                               targetTitle: ()},
    {name: "HubSpot CRM Engagements Tasks",           docsUrl: "https://developers.hubspot.com/docs/api/crm/tasks",                               targetTitle: ()},
    {name: "HubSpot CRM Extensions Timelines",        docsUrl: "https://developers.hubspot.com/docs/api/crm/timeline",                            targetTitle: ()},
    {name: "HubSpot CRM Extensions Videoconferencing",docsUrl: "https://developers.hubspot.com/docs/api/crm/extensions/video-conferencing",       targetTitle: ()},
    {name: "HubSpot Automation Actions",              docsUrl: "https://developers.hubspot.com/docs/api/automation/custom-workflow-actions",       targetTitle: ()},

    // ── HubSpot Marketing ─────────────────────────────────────────────────────
    {name: "HubSpot Marketing Campaigns",     docsUrl: "https://developers.hubspot.com/docs/api/marketing/campaigns",         targetTitle: ()},
    {name: "HubSpot Marketing Emails",        docsUrl: "https://developers.hubspot.com/docs/api/marketing/marketing-email",   targetTitle: ()},
    {name: "HubSpot Marketing Events",        docsUrl: "https://developers.hubspot.com/docs/api/marketing/marketing-events",  targetTitle: ()},
    {name: "HubSpot Marketing Forms",         docsUrl: "https://developers.hubspot.com/docs/api/marketing/forms",             targetTitle: ()},
    {name: "HubSpot Marketing Subscriptions", docsUrl: "https://developers.hubspot.com/docs/api/marketing/subscriptions",     targetTitle: ()},
    {name: "HubSpot Marketing Transactional", docsUrl: "https://developers.hubspot.com/docs/api/marketing/transactional-email", targetTitle: ()},

    // ── Email Marketing ───────────────────────────────────────────────────────
    {name: "Mailchimp Marketing",     docsUrl: "https://mailchimp.com/developer/marketing/api/",     targetTitle: ()},
    {name: "Mailchimp Transactional", docsUrl: "https://mailchimp.com/developer/transactional/api/", targetTitle: ()},

    // ── Cloud Storage ─────────────────────────────────────────────────────────
    {name: "Microsoft OneDrive", docsUrl: "https://learn.microsoft.com/en-us/onedrive/developer/rest-api/", targetTitle: ()},

    // ── AI ────────────────────────────────────────────────────────────────────
    {name: "OpenAI", docsUrl: "https://platform.openai.com/docs/api-reference", targetTitle: ()},

    // ── Payments ──────────────────────────────────────────────────────────────
    {name: "PayPal Invoices",      docsUrl: "https://developer.paypal.com/docs/api/invoicing/v2/",     targetTitle: ()},
    {name: "PayPal Orders",        docsUrl: "https://developer.paypal.com/docs/api/orders/v2/",        targetTitle: ()},
    {name: "PayPal Payments",      docsUrl: "https://developer.paypal.com/docs/api/payments/v2/",      targetTitle: ()},
    {name: "PayPal Subscriptions", docsUrl: "https://developer.paypal.com/docs/api/subscriptions/v1/", targetTitle: ()},
    {name: "Stripe",               docsUrl: "https://docs.stripe.com/api",                              targetTitle: ()},

    // ── Salesforce ────────────────────────────────────────────────────────────
    {name: "Salesforce Marketing Cloud", docsUrl: "https://developer.salesforce.com/docs/marketing/marketing-cloud/references", targetTitle: ()},

    // ── SAP ───────────────────────────────────────────────────────────────────
    // NOTE: SAP API Hub may require authentication; spec may not be publicly accessible.
    {name: "SAP S4HANA Sales", docsUrl: "https://api.sap.com/api/OP_API_SALES_ORDER_SRV_0001/overview", targetTitle: ()},

    // ── Identity ──────────────────────────────────────────────────────────────
    {name: "SCIM", docsUrl: "https://www.simplecloud.info/#api", targetTitle: ()},

    // ── Productivity ──────────────────────────────────────────────────────────
    {name: "Smartsheet", docsUrl: "https://smartsheet.redoc.ly/", targetTitle: ()},

    // ── Customer Support ──────────────────────────────────────────────────────
    {name: "Zendesk", docsUrl: "https://developer.zendesk.com/api-reference/", targetTitle: ()},

    // ── Video Conferencing ────────────────────────────────────────────────────
    {name: "Zoom Meetings",   docsUrl: "https://developers.zoom.us/docs/api/",                targetTitle: ()},
    {name: "Zoom Scheduler",  docsUrl: "https://developers.zoom.us/docs/zoom-scheduler-api/", targetTitle: ()}
];
