# Security Policy

## Sensitive data

The repository must not contain subscription URLs, proxy credentials, device
identifiers, signing certificates, signing passwords, local absolute paths, HAP
packages, or diagnostic exports. User configuration is stored locally by the
application and is not part of the source tree.

If sensitive data is found after publication, remove it from the repository
history, rotate the affected credential or signing material, and publish a
security advisory. Do not disclose the value in a public issue.

## Reporting

Use the repository's private security advisory feature for vulnerability
reports. Public issues should contain only sanitized reproduction steps.
