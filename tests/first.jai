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
        failed_tests: [..] string;

        test :: (expression: bool, message: string) {
            if expression {
                print("PASS :: %\n", message);
            } else {
                array_add(*failed_tests, message);
                print("FAIL :: %\n", message);
            }
        }

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
                                add_build_string(tprint("#run %();", procedure_name), w);
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