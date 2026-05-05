# Ruby on Rails Plugin

When working in a Rails application, prefer the framework's conventions over bespoke architecture. Keep controllers thin, put domain behavior near the model or a small application service when the workflow spans multiple models, use migrations for schema changes, and preserve Rails naming, routing, and autoloading conventions.

Default to incremental changes that are easy to test. Before editing, identify the Rails version, test framework, database adapter, and relevant engines or namespaces from the repository. Prefer existing project patterns over adding new gems or framework layers.

For generated code, favor clear Active Record queries, strong parameters, named routes, standard validations, transactions around multi-record writes, and background jobs for slow external work. Avoid global monkey patches, callback-heavy control flow, broad rescues, and raw SQL unless the local codebase already justifies them.
