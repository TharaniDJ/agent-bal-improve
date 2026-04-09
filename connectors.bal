// connectors.bal
// List of API connectors to discover OpenAPI specs for.
// sourceUrl: the best starting point for discovery — ideally a page that links
//            to the OpenAPI spec, or the vendor's API reference docs page.
// targetTitle: optional — if the vendor publishes multiple specs, name the one
//              we want (e.g. "Support API" for Zendesk vs Sunshine Conversations).

public final Connector[] & readonly ALL_CONNECTORS = [
    {name: "SCIM",           sourceUrl: "https://wso2.com/asgardeo/docs/apis/scim2/",                                                   targetTitle: "SCIM 2.0"},
    {name: "Slack",          sourceUrl: "https://api.slack.com/methods",                                       targetTitle: "Slack Web API"},
    {name: "Smartsheet",     sourceUrl: "https://developers.smartsheet.com/api/smartsheet/openapi",                                                       targetTitle: ()},
    {name: "Stripe",         sourceUrl: "https://github.com/stripe/openapi",                                                 targetTitle: ()},
    {name: "Trello",         sourceUrl: "https://developer.atlassian.com/cloud/trello/rest/",                                targetTitle: ()},
    {name: "Twilio",         sourceUrl: "https://github.com/twilio/twilio-oai",                                              targetTitle: ()},
    {name: "Twitter",        sourceUrl: "https://developer.x.com/en/docs/x-api",                                             targetTitle: ()},
    {name: "Zendesk",        sourceUrl: "https://developer.zendesk.com/api-reference/",               targetTitle: "Ticketing API"},
    {name: "Zoom Meetings",  sourceUrl: "https://developers.zoom.us/docs/api/meetings/",                                     targetTitle: ()}
];
