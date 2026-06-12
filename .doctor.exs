%Doctor.Config{
  min_overall_doc_coverage: 100,
  min_overall_spec_coverage: 100,
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  # Behaviour module — optional callback defaults live in `use MPP.Method`, not as defs here.
  ignore_modules: [MPP.Method],
  raise: true
}
