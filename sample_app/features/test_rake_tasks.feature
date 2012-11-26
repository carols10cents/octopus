Feature: rake db:test:*
  In order to ensure I've configured octopus correctly
  As a developer
  I want to run my tests with my octopus config

  Scenario:
    Given I run inside my Rails project "rake db:migrate" with environment "development"
    When I run inside my Rails project "rake db:test:prepare" with environment "development"
    Then the output should not contain "pending migrations"
    Then I should see file "db/test.sqlite3"
    Then I should see file "db/test_america.sqlite3"
    Then I should see file "db/test_asia.sqlite3"
    Then I should see file "db/test_europe.sqlite3"
