# Rails

Use this skill for Ruby on Rails code generation, debugging, refactoring, and review.

## Defaults

- Read `Gemfile`, `config/application.rb`, `config/routes.rb`, and nearby tests before making Rails-specific changes.
- Follow the app's existing Rails version, test framework, factories, authentication layer, authorization pattern, serializers, and background job adapter.
- Keep controllers focused on request handling: authorization, parameter extraction, orchestration, redirects or rendering.
- Put validations, associations, scopes, and query behavior on models when they naturally belong there.
- Use a service object only when a workflow coordinates multiple models, external systems, or transaction boundaries.
- Prefer reversible migrations and explicit indexes for foreign keys and high-cardinality lookup columns.
- Write or update focused tests for model behavior, request/controller behavior, jobs, mailers, and system flows according to the app's current test style.

## Code Style

- Prefer Rails helpers such as `find_by`, `where`, `includes`, `enum`, `delegate`, `with_options`, `dom_id`, and named route helpers when they improve clarity.
- Avoid introducing new framework abstractions, gems, concerns, callbacks, or metaprogramming unless the surrounding app already uses that pattern.
- Avoid N+1 queries in views, serializers, jobs, and mailers. Use preloading or query restructuring where needed.
- Treat multi-record writes as transaction boundaries and make failure behavior explicit.
- Keep user-facing validation and error handling consistent with the existing app.

## Review Checklist

- Routes, params, authorization, and CSRF behavior are correct for the request type.
- Active Record queries are scoped, indexed where needed, and avoid accidental full-table work.
- Migrations are reversible and safe for existing data.
- Tests cover the behavior change and the failure path when practical.
- Background jobs, mailers, and external calls are idempotent or protected from duplicate execution where needed.
