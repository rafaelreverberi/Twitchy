# Contributing

Build the committed Xcode project and run scripts/build.sh before submitting changes. Keep Swift 6 strict concurrency enabled and add behavior tests for account/security/lifecycle changes. Tests use protocols and fixture responses, never actual secrets. Run mock integration tests for contract changes.

Keep Twitch account services and source video services separate. Do not add unofficial extraction, globally weakened ATS/TLS, telemetry, copyrighted branding or false feature claims. Update the OpenAPI spec and matching models/docs together; v1 additions should be optional and backward compatible.

Use semantic versioning and concise PR descriptions with actual verification and integration boundaries. Optional XcodeGen regeneration must include project.yml and the generated Xcode project. Do not commit .build, certificates, provisioning profiles, credentials or private URLs. Report security issues privately rather than uploading tokens in an issue.
