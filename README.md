# PETAL Blueprint

A production-ready Phoenix 1.8.1 template for building modern web applications.

## Stack Included

- ✅ **Phoenix 1.8.1** - Web framework
- ✅ **Elixir 1.19.2** - Language
- ✅ **Erlang/OTP 28.1.1** - VM
- ✅ **Alpine.js 3.x** - Lightweight interactivity
- ✅ **TailwindCSS 4.1.17** - Utility-first CSS
- ✅ **DaisyUI 5.0.35** - Component library
- ✅ **Mishka Chelekom 0.0.8** - 90+ pre-built components
- ✅ **PostgreSQL 18.1** - Database
- ✅ **Bandit 1.8.0** - HTTP server
- ✅ **LiveView 1.1.17** - Real-time UI
- ✅ **PubSub** - Real-time messaging

## Quick Start

Use this template
git clone https://github.com/JCSchoeman96/PETAL_Blueprint.git my-app
cd my-app

Setup
mix ecto.create
mix phx.server

text

Visit: http://localhost:4000

## Key Features

- ✅ Hot reload (instant feedback)
- ✅ Real-time capabilities (LiveView + PubSub)
- ✅ Beautiful UI (TailwindCSS + DaisyUI)
- ✅ Component-ready (Mishka 90+ components)
- ✅ Alpine.js for interactivity
- ✅ Production-tested
- ✅ Fully configured

## What You Get

- Ready-to-use Phoenix application
- Database configured
- Frontend tooling setup
- Component library installed
- Hot reload enabled
- Development environment ready

## Documentation

- [Setup Guide](./PETAL_COMPLETE_SETUP_WITH_CHECKS.md)
- [Phoenix Docs](https://www.phoenixframework.org/)
- [Alpine.js](https://alpinejs.dev/)
- [TailwindCSS](https://tailwindcss.com/)

## Creating New Projects from Blueprint

### Option 1: GitHub UI (Easiest)
1. Click "Use this template"
2. Create new repository
3. Clone locally
4. Start coding!

### Option 2: Command Line
git clone https://github.com/YOUR_USERNAME/PETAL_Blueprint.git my-new-app
cd my-new-app
mix ecto.create
mix phx.server

text

## Project Structure

lib/
├── petal_blueprint/ # Business logic
│ ├── application.ex
│ └── repo.ex
└── petal_blueprint_web/ # Web layer
├── components/ # 90+ Mishka components
├── controllers/
├── live/
├── router.ex
└── endpoint.ex

assets/
├── js/
│ └── app.js # Alpine.js imported
├── css/
│ └── app.css # TailwindCSS configured
└── package.json # Node dependencies

config/
├── config.exs # Base config
├── dev.exs # Development
├── prod.exs # Production
└── test.exs # Testing

priv/
├── repo/
│ ├── migrations/ # Database migrations
│ └── seeds.exs # Seed data
└── static/ # Static assets


## Common Commands

Development
mix phx.server # Start server
mix format # Format code
mix test # Run tests

Database
mix ecto.create # Create database
mix ecto.migrate # Run migrations
mix ecto.reset # Reset (drop/create/migrate)
mix ecto.gen.migration # Generate new migration

Dependencies
mix deps.get # Install dependencies
mix deps.update # Update dependencies


## Requirements

- Erlang/OTP 28.1+
- Elixir 1.19.2+
- PostgreSQL 18.1+
- Node.js 20+

## License
MIT

## Support

For questions or issues:
1. Check [Phoenix documentation](https://www.phoenixframework.org/)
2. Read [Alpine.js docs](https://alpinejs.dev/)
3. Review [TailwindCSS guide](https://tailwindcss.com/)

---

**Built with ❤️ using Phoenix, Elixir, and modern web technologies.**
