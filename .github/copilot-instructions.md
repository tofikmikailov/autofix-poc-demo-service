# Copilot Instructions

- The project uses Java 21, Spring Boot and Gradle.
- Always make the smallest possible change.
- Add a regression test before or together with a bug fix.
- Run `./gradlew clean test` after changes.
- Do not modify infrastructure files unless explicitly requested.
- Do not add a database.
- Do not change public API contracts without explicit approval.
- Do not disable tests.
- Do not remove exception logging.
- Do not push directly to main.
- Create only a draft pull request.
- Never merge a pull request.
