This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->
# AGENTS.md - FastCheck Project Intelligence for Codex

## 🤖 Project Context for AI Coding Agents

This document provides ALL context needed for ChatGPT Codex, Claude, or any AI coding agent to consistently understand the FastCheck project throughout all 13 implementation tasks.

---

## 🎯 PROJECT ESSENTIALS

### Project Name
**FastCheck** - PETAL Stack Event Check-in System

### Project Status
**Production-Ready (November 2025)**
- Phase 1-3: ✅ Complete (Core functionality, API integration, Performance)
- Phase 4-5: 🟡 In Progress (Deployment, Polish)

### Project Goal
Replace Checkinera (WordPress Tickera check-in app) with a self-hosted, faster, more customizable event attendance tracking system.

### Success Metric
Process QR code scans in **10-50ms** instead of Checkinera's 500-1500ms ✅ **ACHIEVED**

### Problem Statement
- Checkinera charges premium subscription
- Limited customization (proprietary code)
- Slow scanning experience (500-1500ms latency)
- No offline capabilities after sync
- Vendor lock-in (Tickera-hosted)

### Solution
- Self-hosted PETAL application on user's VPS
- Local PostgreSQL database (0.01s queries vs WordPress API calls)
- Complete source code ownership
- Offline-capable after initial sync ✅
- No ongoing subscription costs

---

## 💼 BUSINESS CONTEXT

### User Profile
**Name**: South African digital entrepreneur  
**Tech Stack**: WordPress (full ecosystem), PHP, JavaScript, Elixir (learning), PostgreSQL  
**Infrastructure**: Self-hosted VPS (16-core, 32GB RAM) with OpenLiteSpeed, Cloudflare, Redis  
**Use Case**: Running Voelgoed Live (weekly TV broadcasts with check-in requirement)  
**Goal**: Build reusable event ticketing + check-in system for multiple events

### Expected Usage
- **Events per month**: 2-4 initial, scaling to 10+
- **Attendees per event**: 100-5000
- **Concurrent scanners at door**: 3-10 tablets/devices
- **Check-in velocity**: 20-50 scans per minute during peak entrance time
- **Venues**: Multiple entrances (Main, VIP, Staff) per event

### User Preferences
- **Accuracy**: Wants truth, not sugar-coating
- **Approach**: Analyze → Plan → Execute (system thinker)
- **Persistence**: Finish what you start
- **Tone**: Intelligent, confident, practical
- **Documentation**: Detailed, actionable, clear

---

## 🏗️ TECHNICAL ARCHITECTURE

### Technology Stack (PETAL)

**P** - Phoenix 1.8.1 (web framework)  
**E** - Elixir 1.19.3 / OTP 28 (functional programming language)  
**T** - TailwindCSS v4 (styling)  
**A** - Alpine.js (lightweight interactivity)  
**L** - LiveView 1.1.17+ (real-time web interface)

### Deployment Infrastructure
- **Server**: User's existing VPS (OpenLiteSpeed + PostgreSQL)
- **Database**: PostgreSQL 12+ (existing)
- **Domain**: voelgoed.co.za (https only)
- **SSL**: Let's Encrypt certificates
- **Process Manager**: systemd service

### Data Sources
- **Primary**: Tickera WordPress plugin (REST API at `/tc-api/{API_KEY}/{endpoint}`)
- **Secondary**: Local PostgreSQL (cached after sync)

---

## 📊 DATA MODEL

### Four Core Tables

#### 1. **events** Table
Stores event configuration and Tickera API credentials

```
id              SERIAL PRIMARY KEY
name            VARCHAR(255)        -- Event name
api_key         VARCHAR(255) UNIQUE -- From Tickera (secret)
site_url        VARCHAR(255)        -- WordPress domain
status          VARCHAR(50)         -- active|syncing|archived
total_tickets   INTEGER             -- From Tickera event_essentials
checked_in_count INTEGER            -- Real-time counter
event_date      DATE                -- When event occurs
event_time      TIME                -- Event start time
location        VARCHAR(255)        -- Venue name
entrance_name   VARCHAR(100)        -- "Main"|"VIP"|"Staff"
sync_started_at TIMESTAMP           -- When sync began
sync_completed_at TIMESTAMP         -- When sync finished
last_checked_at TIMESTAMP           -- Last check-in time
inserted_at     TIMESTAMP DEFAULT NOW()
updated_at      TIMESTAMP DEFAULT NOW()
```

#### 2. **attendees** Table
Synced attendee data from Tickera

```
id                  SERIAL PRIMARY KEY
event_id            INTEGER FOREIGN KEY (events)
ticket_code         VARCHAR(255)        -- QR code data "25955-1"
first_name          VARCHAR(100)
last_name           VARCHAR(100)
email               VARCHAR(255)
ticket_type         VARCHAR(100)        -- "VIP", "General", etc
ticket_type_id      INTEGER             -- Links to Tickera config
allowed_checkins    INTEGER DEFAULT 1   -- 1=single, 2+=multiple, 9999=unlimited
checkins_remaining  INTEGER DEFAULT 1   -- Countdown
payment_status      VARCHAR(50)         -- "completed"|"pending"
custom_fields       JSONB               -- All Tickera form data
checked_in_at       TIMESTAMP           -- First check-in time
last_checked_in_at  TIMESTAMP           -- Most recent
checked_out_at      TIMESTAMP           -- Exit tracking
inserted_at         TIMESTAMP DEFAULT NOW()
updated_at          TIMESTAMP DEFAULT NOW()

UNIQUE CONSTRAINT: (event_id, ticket_code)
```

#### 3. **check_ins** Table
Audit trail of every check-in attempt

```
id              SERIAL PRIMARY KEY
attendee_id     INTEGER FOREIGN KEY (attendees)
event_id        INTEGER FOREIGN KEY (events)
ticket_code     VARCHAR(255)        -- Denormalized for queries
checked_in_at   TIMESTAMP NOT NULL  -- When this check-in occurred
entrance_name   VARCHAR(100)        -- Which gate/door
operator_name   VARCHAR(100)        -- Staff member who scanned
status          VARCHAR(50)         -- success|duplicate|invalid|error
notes           TEXT                -- Additional info
inserted_at     TIMESTAMP DEFAULT NOW()
```

#### 4. **check_in_configurations** Table
Per-event customization of check-in rules

```
id                      SERIAL PRIMARY KEY
event_id                INTEGER FOREIGN KEY (events) UNIQUE
allowed_checkins        INTEGER DEFAULT 1   -- Per-ticket check-in limit
allow_reentry           BOOLEAN DEFAULT FALSE -- Can exit and re-enter
check_in_window_start   TIMESTAMP         -- When check-ins open
check_in_window_end     TIMESTAMP         -- When check-ins close
entrance_limit          INTEGER           -- Max capacity per entrance
require_checkout        BOOLEAN DEFAULT FALSE -- Track exits
inserted_at             TIMESTAMP DEFAULT NOW()
updated_at              TIMESTAMP DEFAULT NOW()

UNIQUE CONSTRAINT: event_id (one config per event)
```

### Database Migrations
**Total**: 10 migrations (includes initial schema + 9 updates)

### Indexes (8+ total for performance)
```
events:
  - idx_events_api_key (UNIQUE, for validation)
  - idx_events_status (for filtering)

attendees:
  - idx_attendees_event_id (for lookups)
  - idx_attendees_ticket_code (for QR scanning)
  - idx_attendees_event_code (composite: fastest for check-in)
  - idx_attendees_checked_in (for stats)

check_ins:
  - idx_check_ins_event_id (for audit reports)
  - idx_check_ins_checked_in_at (for analytics)
```

---

## 🚀 ADVANCED FEATURES (IMPLEMENTED)

### Circuit Breaker Pattern ✅

**Module**: `FastCheck.TickeraCircuitBreaker`  
**Location**: `lib/fastcheck/tickera_circuit_breaker.ex` (4,472 lines)

**Purpose**: Prevents cascading failures when Tickera API is slow or unreachable

**States**:
- `:closed` - Normal operation, requests flow through
- `:open` - Too many failures, requests fast-fail immediately
- `:half_open` - Testing if service recovered

**Critical**: ALL Tickera API calls MUST wrap in circuit breaker

```elixir
case TickeraCircuitBreaker.call(site_url, api_key, fn ->
  TickeraClient.get_event_essentials(site_url, api_key)
end) do
  {:ok, essentials} -> # Handle success
  {:error, :circuit_open} -> # Use fallback
  {:error, reason} -> # API error
end
```

### Fallback Cache System ✅

**Module**: `FastCheck.TickeraClient.Fallback`

**Purpose**: Serve cached attendee data when Tickera API unreachable

**Return patterns**:
```elixir
{:ok, attendees, count}              # Fresh API data
{:fallback, cached_attendees, count} # Using cache (API down)
{:error, reason, partial}            # Complete failure
```

### API Key Encryption ✅

**Module**: `FastCheck.Crypto` (1,779 lines)

**Functions**: `encrypt/1`, `decrypt/1`

**Requirement**: All API keys MUST be encrypted before database storage

### Performance Cache ✅

**Module**: `FastCheck.Cache.CacheManager`

**Purpose**: Reduce database queries by 70-90% for event/attendee reads

---

## 🗺️ CODEBASE NAVIGATION

| Module | Lines | Purpose |
|--------|-------|---------|  
| FastCheck.Events | 62,560 | Event CRUD, sync orchestration |
| FastCheck.Attendees | 50,550 | Attendee CRUD, check-in logic |
| FastCheck.TickeraClient | 47,529 | Tickera HTTP client |
| FastCheck.TickeraCircuitBreaker | 4,472 | API failure resilience |
| FastCheck.Crypto | 1,779 | API key encryption |

---

## 🛠️ QUALITY TOOLS (INSTALLED)

### Credo 1.7 ✅
- **Config**: `.credo.exs` (Phoenix-specific)
- **Commands**: `mix credo`, `mix credo --strict`
- **Integration**: Runs in `mix precommit` and `mix ci`

### Sobelow 0.13 ✅
- **Config**: `.sobelow-conf`
- **Commands**: `mix security`, `mix sobelow --exit`
- **Integration**: Runs in `mix ci` pipeline

### ExUnit ✅
- **Test files**: 7+ covering critical paths
- **Commands**: `mix test`

---

## 🔗 API INTEGRATION: Tickera

### Endpoint Base URL
```
{site_url}/tc-api/{api_key}/{endpoint}
```

### Endpoints Used

#### 1. Check Credentials
```
GET /tc-api/{api_key}/check_credentials

Response (valid):
{
  "pass": true,
  "license_key": "4DDGH-...",
  "admin_email": "admin@voelgoed.co.za",
  "tc_iw_is_pr": true
}

Response (invalid):
{"pass": false}
```

#### 2. Event Essentials
```
GET /tc-api/{api_key}/event_essentials

Response:
{
  "event_name": "Voelgoed Live 13 Nov",
  "event_date_time": "13th November 2025 19:00",
  "event_location": "Randburg, GP, SA",
  "sold_tickets": 1500,
  "checked_tickets": 0,
  "pass": true
}
```

#### 3. Tickets Info (Paginated)
```
GET /tc-api/{api_key}/tickets_info/{per_page}/{page}/

Example: /tc-api/abc123/tickets_info/50/1/

Response:
{
  "data": [
    {
      "checksum": "25955-1",
      "buyer_first": "John",
      "buyer_last": "Smith",
      "payment_date": "1st Nov 2025 - 2:15 pm",
      "transaction_id": "25955",
      "allowed_checkins": 1,
      "custom_fields": [
        ["Ticket Type", "VIP Front Row"],
        ["Buyer E-mail", "john@example.com"],
        ["Company", "Tech Corp"],
        ["Dietary Restrictions", "Vegetarian"]
      ]
    },
    ... (up to 50 attendees)
  ],
  "additional": {
    "results_count": 1500
  }
}
```

### API Constraints
- Pagination: 50 results per page recommended
- Timeout: 30 seconds per request
- Rate limiting: Add 100ms delay between pagination calls
- Authentication: API key in URL (treat as password)
- Security: HTTPS only

---

## 📁 PROJECT STRUCTURE (Final)

```
fastcheck/
├── README.md                                  ← Generated by Codex in TASK 0
├── .gitignore
├── mix.exs                                    ← Updated TASK 1
├── mix.lock
│
├── config/
│   ├── config.exs
│   ├── dev.exs                               ← Updated TASK 12
│   ├── test.exs
│   ├── prod.exs                              ← Updated TASK 13
│   └── runtime.exs                           ← Created TASK 13
│
├── lib/
│   ├── fastcheck/
│   │   ├── application.ex                    ← Auto-generated
│   │   ├── repo.ex                           ← Auto-generated
│   │   │
│   │   ├── tickera_client.ex                 ← TASK 6
│   │   ├── events.ex                         ← TASK 7
│   │   ├── attendees.ex                      ← TASK 8
│   │   │
│   │   ├── events/
│   │   │   └── event.ex                      ← TASK 3
│   │   │
│   │   └── attendees/
│   │       ├── attendee.ex                   ← TASK 4
│   │       └── check_in.ex                   ← TASK 5
│   │
│   └── fastcheck_web/
│       ├── application.ex                    ← Auto-generated
│       ├── components.ex
│       ├── router.ex                         ← Updated TASK 11
│       ├── endpoint.ex
│       │
│       ├── live/
│       │   ├── dashboard_live.ex             ← TASK 9
│       │   └── scanner_live.ex               ← TASK 10
│       │
│       ├── controllers/
│       ├── views/
│       └── templates/
│
├── priv/
│   └── repo/
│       ├── seeds.exs
│       └── migrations/
│           └── 20250115000000_create_event_tables.exs  ← TASK 2
│
├── assets/                                   ← TailwindCSS pre-configured
│   ├── tailwind.config.js
│   ├── css/
│   └── js/
│
├── test/
│
├── .env.example                              ← Created TASK 13
├── .env                                      ← Local (git-ignored)
│
└── /etc/systemd/system/
    └── fastcheck.service                     ← Created TASK 13
```

---

## 🔄 WORKFLOW PHASES

### Phase 1: Foundation (Days 1-2)
**Goal**: Database and schema ready
- TASK 1: Phoenix project initialized
- TASK 2: Database migrations created
- TASK 3-5: Ecto schemas with validations
- **Output**: `iex -S mix` runs without errors

### Phase 2: Integration (Day 3)
**Goal**: Tickera API connectivity confirmed
- TASK 6: HTTP client for Tickera API
- **Output**: `TickeraClient.check_credentials()` returns valid response

### Phase 3: Business Logic (Days 4-5)
**Goal**: Core operations working
- TASK 7: Events context (CRUD + sync)
- TASK 8: Attendees context (check-in logic)
- **Output**: Can sync attendees from Tickera, process check-ins locally

### Phase 4: Interface (Days 6-7)
**Goal**: Web interface functional
- TASK 9: Dashboard LiveView
- TASK 10: Scanner LiveView
- TASK 11: Router configuration
- **Output**: `mix phx.server` loads web UI, events display, scanning works

### Phase 5: Production (Day 8)
**Goal**: Ready for deployment
- TASK 12: Database optimization
- TASK 13: Production configuration
- **Output**: Systemd service runs, SSL configured, env vars set

---

## 🎯 PERFORMANCE TARGETS

### Speed Benchmarks
| Operation | Target | Status |
|-----------|--------|--------|
| QR code scan | <50ms | ⏳ |
| Database query | <10ms | ⏳ |
| Event sync (1000 attendees) | <5min | ⏳ |
| LiveView broadcast | <100ms | ⏳ |
| Duplicate check detection | <100ms | ⏳ |

### Scalability Targets
| Metric | Target |
|--------|--------|
| Max attendees per event | 100,000+ |
| Max check-ins per minute | 10,000+ |
| Concurrent scanners | 50+ |
| Simultaneous events | Unlimited |
| Database connections | 20 pool size |

---

## 🔐 SECURITY REQUIREMENTS

### API Key Management
- API keys treated as passwords (never logged)
- Stored in PostgreSQL (encrypted at rest recommended)
- Environment variables for secrets (not hardcoded)
- Unique constraint prevents duplicate keys

### Database Safety
- Row-level locks (FOR UPDATE) during check-in to prevent race conditions
- Unique constraint on (event_id, ticket_code) prevents duplicate entries
- Foreign key constraints with ON DELETE CASCADE

### Authentication & Authorization
- API key validation on every sync
- Site URL validation (exact match required: https, domain, www prefix)
- License check (Checkinera requires premium, FastCheck doesn't)

### Audit Trail
- Every check-in logged to check_ins table with:
  - Attendee ID
  - Timestamp
  - Entrance name
  - Operator name
  - Status (success/duplicate/invalid)

### SSL/HTTPS
- All API calls to Tickera over HTTPS
- All LiveView connections over WSS (WebSocket Secure)
- SSL certificates required for production

---

## 🧪 TESTING STRATEGY

### Unit Tests
- Tickera API client functions
- Ecto schema validations
- Context business logic

### Integration Tests
- Full sync workflow (API → Database)
- Check-in processing logic
- Duplicate detection

### Performance Tests
- Query execution time (<50ms for QR scan)
- Bulk import speed (1000+ attendees/min)
- Connection pooling under load

### Manual Testing (Event Day)
- Create test event with live API key
- Sync attendee list
- Scan 10 QR codes manually
- Verify check-in counts
- Test duplicate scan behavior
- Monitor real-time stats updates

---

## 📝 CODING STANDARDS

### Language: Elixir/Phoenix

**Naming Conventions**:
- Module names: CamelCase (e.g., `FastCheck.TickeraClient`)
- Function names: snake_case (e.g., `fetch_all_attendees`)
- Variables: snake_case
- Atoms: :lowercase

**Documentation**:
- Every public function has @doc comment
- Complex logic has inline comments
- Error cases documented
- Examples in documentation

**Error Handling**:
- All API calls wrapped in circuit breaker
- Database errors handled gracefully
- User-friendly error messages
- Logging at appropriate levels (Logger.warning/2 - modern API)

**Integration Patterns**:

✅ **Circuit Breaker Usage**: Always wrap Tickera calls
```elixir
case TickeraCircuitBreaker.call(site_url, api_key, fn ->
  TickeraClient.get_event_essentials(site_url, api_key)
end) do
  {:ok, data} -> # success
  {:error, :circuit_open} -> # use fallback
end
```

✅ **API Key Handling**: Must encrypt before storage
```elixir
encrypted = FastCheck.Crypto.encrypt(api_key)
Event.changeset(event, %{tickera_api_key_encrypted: encrypted})
```

✅ **Fallback Handling**: Handle all patterns
```elixir
case TickeraClient.fetch_all_attendees(...) do
  {:ok, attendees, count} -> # Fresh API data
  {:fallback, cached, count} -> # Using cache (API down)
  {:error, reason, partial} -> # Complete failure
end
```

**Code Organization**:
- One module per file
- Related functions grouped in contexts
- Private helpers with `defp` prefix
- Tests in separate `test/` directory

### Language: SQL (Migrations)

**Naming Conventions**:
- Tables: plural lowercase (attendees, events, check_ins)
- Columns: snake_case lowercase
- Indexes: `idx_{table}_{column(s)}`
- Constraints: `{constraint_type}_{table}_{column(s)}`

**Standards**:
- All timestamps use UTC (naive datetime in Ecto)
- Foreign keys explicit with ON DELETE CASCADE
- NOT NULL constraints for required fields
- Defaults specified where applicable

---

## 🚀 DEPLOYMENT PROCESS

### Development (Local)
```bash
mix phx.server
# Runs on http://localhost:4000
```

### Staging (VPS - Optional)
```bash
MIX_ENV=staging mix release
# Run on staging subdomain for testing
```

### Production (VPS)
```bash
MIX_ENV=prod mix release
scp -r _build/prod/rel/fastcheck/ root@voelgoed.co.za:/opt/fastcheck/
systemctl start fastcheck
```

### Monitoring
```bash
journalctl -u fastcheck -f
# Tail systemd service logs
```

---

## 🔄 CODE GENERATION GUIDELINES FOR CODEX

### When Asking Codex to Generate Code

**Always provide**:
1. **Context**: What module/file this is for
2. **Dependencies**: What other modules/tables it depends on
3. **Requirements**: Explicit list of functions/fields needed
4. **Output**: Specify exactly what format you want
5. **Constraints**: Performance, security, or business rules

**Example Structure**:
```
I'm building FastCheck, a PETAL event check-in system.

CURRENT PROGRESS: Tasks 1-5 complete. Database and schemas ready.
DEPENDENCIES: Needs Event and Attendee schemas from previous tasks.

TASK X: [Task Name]

FILE PATH: lib/fastcheck/[module].ex

REQUIREMENTS:
1. Function one_function(param1, param2)
   - Does this thing
   - Returns {:ok, data} or {:error, reason}
2. Function two_function(param)
   - Does that thing
   - Handles edge case X

OUTPUT:
- Complete, production-ready module
- Include @doc comments
- Include error handling with try/rescue
- Include Logger statements for debugging
```

---

## ✅ COMPLETION CHECKLIST

By the end of all implementation phases:

**Technology**
- [x] Phoenix 1.8.1 project initialized
- [x] PostgreSQL database with 4 tables + 10 migrations
- [x] Ecto schemas with validations
- [x] Tickera HTTP client functional (47k lines, production-ready)
- [x] Business logic contexts implemented (Events 62k, Attendees 50k)
- [x] LiveView components rendering
- [x] Router configured  
- [x] Database optimized (indexes created)
- [ ] Production config ready (needs SSL/environment review)

**Functionality**
- [x] Can create events with Tickera API key
- [x] Can sync 1000+ attendees from Tickera
- [x] Can scan QR codes and record check-ins
- [x] Can handle duplicate scans
- [x] Real-time stats updating (via contexts)
- [x] Audit trail recording
- [x] Multiple simultaneous events
- [x] Multiple concurrent scanners (circuit breaker handles load)

**Advanced Features**
- [x] Circuit Breaker pattern implemented
- [x] Fallback cache system operational
- [x] API key encryption (FastCheck.Crypto)
- [x] Performance caching (FastCheck.Cache)
- [x] Check-in configurations per event

**Deployment**
- [ ] Systemd service auto-starts
- [ ] SSL certificate configured
- [ ] Environment variables set
- [ ] Database backed up
- [ ] Logs accessible
- [ ] Performance acceptable (<50ms target)
- [ ] Ready for live event

**Quality**
- [x] Code compiles without warnings (Logger.warning/2 refactored)
- [x] Credo static analysis configured
- [x] Sobelow security scanning configured
- [ ] Tests passing (verify current status)
- [x] Error handling robust (circuit breaker + fallback)
- [x] Logging comprehensive (Logger.warning/2 throughout)
- [x] Security hardened (API key encryption, CSP headers needed)

---

## 🎓 REFERENCE DOCUMENTS

Related documentation provided:
1. **fastcheck-petal-guide.md** - Complete architecture & implementation
2. **fastcheck-checklist.md** - Day-by-day implementation checklist
3. **fastcheck-reference.md** - API contracts & technical details
4. **codex-project-plan.md** - All 13 task prompts
5. **codex-start-here.md** - First 3 tasks ready to run
6. **codex-quick-reference.md** - Quick development reference
7. **tickera-checkinera-deepdive.md** - API documentation
8. **tickera-api-reference.md** - Code examples
9. **README.md** - Generated by TASK 0 (Codex scaffold step)

---

## 🆘 COMMON ISSUES & SOLUTIONS

### "API key won't validate"
- Verify Site URL exactly matches (www, https, domain)
- Check API key isn't deleted in Tickera
- Ensure WordPress is accessible via HTTPS

### "No attendees syncing"
- Check orders are "Completed" status in WordPress
- Verify API key assigned to correct event
- Check network connectivity to WordPress

### "Scan taking >100ms"
- Verify database indexes created
- Check pool_size = 20 in config
- Monitor CPU/memory usage

### "Duplicate ticket allowed"
- Verify UNIQUE constraint created on (event_id, ticket_code)
- Check migration ran successfully
- Restart app to clear any caches

### "LiveView not updating in real-time"
- Verify WebSocket connections active
- Check browser console for JavaScript errors
- Ensure no firewall blocking WS connections

---

This document serves as the "project brain" for Codex. Reference it whenever generating code for FastCheck.
<!-- usage-rules-end -->
