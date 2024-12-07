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

    compiler_begin_intercept(w);

    add_build_string(#string jai
        test :: (description: string, proc: () -> ()) {
            context.current_test_description = description;
            proc();
        }

        expect :: (expression: bool, loc := #caller_location) {
            if expression {
                print("PASS :: %\n", context.current_test_description);
            } else {
                message := sprint("FAIL :: % - %", context.current_test_description, loc);
                print("%\n", message);
            }
        }

        #add_context current_test_description: string;

        #import "Basic";
    jai, w);

    add_build_file(tprint("%/main.jai", #filepath), w);

    message_loop(w);

    compiler_end_intercept(w);
}

message_loop :: (w: Workspace) {
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
                                add_build_string(tprint("#run,stallable %();", procedure_name), w);
                                break;
                            }
                        }
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