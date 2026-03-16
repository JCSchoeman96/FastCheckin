# This file contains the configuration for Credo
# Generated lean config for Phoenix 1.8+ apps
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          # Migrations are generated and not worth linting
          ~r"/priv/repo/migrations/"
        ]
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          ## Consistency Checks
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          ## Design Checks
          {Credo.Check.Design.AliasUsage,
           [
             exit_status: 0,
             priority: :low,
             # Phoenix web modules use many aliases - don't warn
             excluded_namespaces: ["FastCheckWeb", "Phoenix", "Ecto"],
             # Only warn if a module is referenced more than 2 times without alias
             if_called_more_often_than: 2
           ]},
          {Credo.Check.Design.TagFIXME, []},
          # TODO tags are informational only - don't fail builds
          {Credo.Check.Design.TagTODO, [exit_status: 0]},

          ## Readability Checks
          {Credo.Check.Readability.AliasOrder, [exit_status: 0]},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          # Phoenix apps benefit from slightly longer lines for DSL readability
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          # Phoenix.Endpoint is generated, doesn't need @moduledoc
          {Credo.Check.Readability.ModuleDoc,
           [exit_status: 0, ignore_names: [~r/FastCheckWeb\.Endpoint/]]},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, [exit_status: 0]},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, [exit_status: 0]},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, [exit_status: 0]},

          ## Refactoring Opportunities
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, [exit_status: 0]},
          # LiveViews and controllers can legitimately have higher complexity
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 20, exit_status: 0]},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, [exit_status: 0]},
          {Credo.Check.Refactor.MapJoin, [exit_status: 0]},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # Allow up to 3 levels of nesting - enough for real logic, strict enough to catch pyramids of doom
          {Credo.Check.Refactor.Nesting, [max_nesting: 4, exit_status: 0]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          ## Warnings
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, [exit_status: 0]},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []}
        ],
        disabled: [
          # Disabled by default - uncomment to enable if desired
          # {Credo.Check.Readability.Specs, []},
          # {Credo.Check.Readability.StrictModuleLayout, []},
          # {Credo.Check.Design.DuplicatedCode, []}
        ]
      }
    }
  ]
}
