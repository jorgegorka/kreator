# Ruby on Rails Plugin

When working in a Rails application, prefer the framework's conventions over bespoke architecture. Preserve Rails naming, routing, autoloading, migrations, Active Record associations, and test conventions already present in the app.

Default to rich models and thin controllers. Put domain behavior, state transitions, business decisions, and multi-record workflows on models or cohesive model concerns. Avoid service objects.

Model user actions as RESTful resources instead of custom controller actions. Controllers should load authorized records, call intention-revealing model methods, then render or redirect. Jobs should be ultra-thin wrappers around synchronous model methods, with `_later` methods used for enqueueing when that pattern fits the app.

For generated code, favor clear Active Record relations, smart association defaults, descriptive scopes, strong parameters, named routes, standard validations, and transactions around related writes. Use callbacks sparingly for consistency, async enqueueing after commit, and cache touching; keep complex business logic explicit.

Default to incremental, focused changes that are easy to test. Before editing, identify the Rails version, test framework, database adapter, authentication/current-context setup, authorization pattern, and relevant engines or namespaces. Avoid global monkey patches, broad rescues, callback-heavy control flow, raw SQL, new gems, and new framework layers unless the local codebase clearly justifies them.
