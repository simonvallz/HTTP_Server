test :: () {
    set_build_options_dc(.{do_output=false});

    w := compiler_create_workspace("Tests");
    if !w {
        print("Workspace creation failed.\n");
        return;
    }

    target_options := get_build_options(w);
    target_options.output_type = .NO_OUTPUT;
    set_build_options(target_options, w);

    compiler_begin_intercept(w, .SKIP_EXPRESSIONS_WITHOUT_NOTES);

    add_build_string(#string jai
        test :: (description: string, proc: () -> ()) {
            context.one_or_more_expect_failed_in_this_test = false;

            proc();

            if context.one_or_more_expect_failed_in_this_test {
                context.one_or_more_tests_failed = true;
                print("FAIL :: %\n", description);
            } else {
                print("PASS :: %\n", description);
            }
        }

        expect :: (expression: bool, loc := #caller_location) {
            if !expression  context.one_or_more_expect_failed_in_this_test = true;
        }

        #add_context one_or_more_tests_failed: bool;
        #add_context one_or_more_expect_failed_in_this_test: bool;

        #import "Basic";
    jai, w);

    add_build_file(tprint("%/main.jai", #filepath), w);

    message_loop(w);

    compiler_end_intercept(w);
}

message_loop :: (w: Workspace) {
    test_procs: [..] string;

    while true {
        message := compiler_wait_for_message();

        if message.kind == {
            case .TYPECHECKED;
                typechecked := cast(*Message_Typechecked) message;

                for typechecked.procedure_headers {
                    if starts_with(it.expression.location.enclosing_load.fully_pathed_filename, #filepath) {
                        procedure_name := it.expression.name;

                        for it.expression.notes {
                            if it.text == "test" {
                                array_add(*test_procs, procedure_name);
                                break;
                            }
                        }
                    }
                }

            case .PHASE;
                phase := cast(*Message_Phase) message;

                if phase.phase == .TYPECHECKED_ALL_WE_CAN {
                    if test_procs.count > 0 {
                        code: String_Builder;

                        append(*code, "#run {\n");

                        for test_procs {
                            append(*code, tprint("    %();\n", it));
                        }

                        append(*code, #string jai
                            if context.one_or_more_tests_failed {
                                print("\n\nSOME TESTS FAILED!!!\n");

                                exit(1);
                            }
                        jai);

                        append(*code, "}\n");

                        add_build_string(builder_to_string(*code), w);

                        array_reset(*test_procs);
                    }
                }

            case .COMPLETE;
                break;
        }
    }
}

#run test();

#import "Basic";
#import "Compiler";
#import "String";