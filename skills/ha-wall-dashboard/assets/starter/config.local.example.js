// Copy to config.local.js and paste a long-lived access token
// (HA: your profile -> Security -> Long-lived access tokens).
//
// config.local.js is gitignored, but it IS served: anyone on your network who
// knows the URL can read this token. Use a dedicated HA user for the wall
// tablet (non-admin if you can), so revoking it never locks you out, and so
// the logbook tells the tablet's taps apart from yours.
export const HA_TOKEN = 'PASTE_LONG_LIVED_TOKEN_HERE';
