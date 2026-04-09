// connectors.bal
// List of API connectors to discover OpenAPI specs for.
// sourceUrl: the best starting point for discovery — ideally a page that links
//            to the OpenAPI spec, or the vendor's API reference docs page.
// targetTitle: optional — if the vendor publishes multiple specs, name the one
//              we want (e.g. "Support API" for Zendesk vs Sunshine Conversations).

public final Connector[] & readonly ALL_CONNECTORS = [
    {name: "SCIM",           sourceUrl: "https://github.com/wso2/docs-is",                                                   targetTitle: "SCIM 2.0"},
    {name: "Slack",          sourceUrl: "https://github.com/slackapi/slack-api-specs",                                       targetTitle: "Slack Web API"},
    {name: "Smartsheet",     sourceUrl: "https://smartsheet.redoc.ly",                                                       targetTitle: ()},
    {name: "Stripe",         sourceUrl: "https://github.com/stripe/openapi",                                                 targetTitle: ()},
    {name: "Trello",         sourceUrl: "https://developer.atlassian.com/cloud/trello/rest/",                                targetTitle: ()},
    {name: "Twilio",         sourceUrl: "https://github.com/twilio/twilio-oai",                                              targetTitle: ()},
    {name: "Twitter",        sourceUrl: "https://developer.x.com/en/docs/x-api",                                             targetTitle: ()},
    {name: "Zendesk",        sourceUrl: "https://developer.zendesk.com/api-reference/ticketing/introduction/",               targetTitle: "Ticketing API"},
    {name: "Zoom Meetings",  sourceUrl: "https://developers.zoom.us/docs/api/meetings/",                                     targetTitle: ()}
];
