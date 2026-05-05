# Rails

Use this skill for Ruby on Rails code generation, debugging, refactoring, and review. This is an opinionated Rails style: use the framework deeply, keep business logic in models, and let controllers, jobs, and views orchestrate model APIs.

## Defaults

- Read `Gemfile`, `config/application.rb`, `config/routes.rb`, and nearby tests before making Rails-specific changes.
- Follow the app's existing Rails version, test framework, fixtures/factories, authentication layer, `Current` context, authorization pattern, serializers, and background job adapter.
- Prefer the existing app's conventions over any rule here when they conflict.
- Put business logic in models. Do not introduce service objects as the default home for domain behavior.
- Keep controllers focused on HTTP: load authorized records, extract params, call one or a few intention-revealing model methods, then render or redirect.
- Keep jobs ultra-thin. A job should usually call one synchronous model method.
- Use CRUD routes and RESTful controller actions. Model actions as resources instead of custom member/collection actions.
  * Example: instead of `AgendasController#add_availability` and `#remove_availability`, create and destroy an `Agendas::AvailabilitiesController` resource.
- Write or update focused tests for model behavior, request/controller behavior, jobs, mailers, and system flows according to the app's current test style.

## Model Design

- Put validations, associations, scopes, query behavior, state transitions, and multi-record domain workflows on models when they naturally belong there.
- Use intention-revealing APIs: boolean methods end in `?`, action methods use imperative verbs, and method names describe domain concepts instead of implementation details.
- Provide readable delegations or wrapper methods when they prevent callers from reaching through associations.
- Wrap related multi-record writes and event/audit creation in a transaction.
- Use `belongs_to` lambda defaults for tenant/account and creator/user context when those values are always derived from parent associations or `Current.user`.
- Declare associations before using them in lambda defaults.
- Use descriptive, chainable scopes that read like business concepts, not SQL operations. Add preloading scopes where views, serializers, jobs, or mailers would otherwise cause N+1 queries.

## Concerns

- Use shared concerns in `app/models/concerns` for cross-cutting behavior used by multiple unrelated models.
- Use model-specific concerns such as `Card::Closeable` for cohesive behavior owned by one model when it would otherwise make the model hard to scan.
- Keep concerns cohesive. Do not extract one or two simple methods just to reduce file length.
- Concerns should expose clear public model APIs and keep private helpers below `private`.
- Template-method hooks are acceptable when a shared concern needs small model-specific overrides.

## Controllers and Routes

- Prefer nested or singular resources for stateful actions: closing creates a `Closure`, assigning creates an `Assignment`, pinning creates a `Pin`.
- Avoid custom routes like `post :close`, `post :reopen`, `post :add_user`, or `post :remove_user` when a resource can represent the change.
- Extract controller concerns only for repeated resource loading, authorization, or response helpers used by several controllers.
- Keep complex query selection out of controllers by moving it into scopes such as `indexed_by`, `sorted_by`, or explicit query methods.

## Background Jobs

- Prefer the `_later` pattern when enqueueing model-owned work:
  * `record.notify_recipients` performs the synchronous operation.
  * `record.notify_recipients_later` enqueues the job.
  * `NotifyRecipientsJob#perform(record)` calls `record.notify_recipients`.
- Enqueue jobs from `after_*_commit` callbacks when the job depends on committed database state.
- Do not manually pass account/tenant context to jobs when the app already captures it through `Current` or Active Job extensions.
- Make jobs idempotent or protected from duplicate execution when retries are possible.

## Code Style

- Prefer Rails helpers such as `find_by`, `where`, `includes`, `enum`, `delegate`, `with_options`, `dom_id`, and named route helpers when they improve clarity.
- Avoid introducing new framework abstractions, gems, concerns, callbacks, or metaprogramming unless the surrounding app already uses that pattern.
- Avoid N+1 queries in views, serializers, jobs, and mailers. Use preloading or query restructuring where needed.
- Treat multi-record writes as transaction boundaries and make failure behavior explicit.
- Keep user-facing validation and error handling consistent with the existing app.
- Prefer expanded conditionals over guard clauses when it improves readability. Guard clauses are fine at the start of non-trivial methods.
- Order methods as class methods, public methods, then private methods. Keep private methods in invocation order where practical.
- Do not add a blank line after `private`; indent private methods if the surrounding app uses that style.
- Use `!` only when there is a meaningful non-bang counterpart.
- Avoid broad rescues, raw SQL, global monkey patches, callback-heavy control flow, and new gems unless the local codebase already justifies them.

## Review Checklist

- Routes, params, authorization, and CSRF behavior are correct for the request type.
- Active Record queries are scoped, indexed where needed, and avoid accidental full-table work.
- Migrations are reversible, safe for existing data, and include indexes for foreign keys and high-cardinality lookup columns where appropriate.
- Tenant/account and creator/user context are set consistently, especially in tests that rely on `Current`.
- Business logic lives on models or cohesive model concerns, not controllers or jobs.
- RESTful resources were used instead of custom actions where possible.
- Tests cover the behavior change and the failure path when practical. No system tests. Only unit and integration tests that follow the app's existing style.
- Use travel_to to freeze time in tests when the behavior depends on time. Avoid Timecop or other gems if the app doesn't already use them.
- Background jobs, mailers, and external calls are idempotent or protected from duplicate execution where needed.
