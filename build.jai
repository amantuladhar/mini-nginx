
#run build();

build:: () {
    w := compiler_create_workspace("mini-nginx");
    options := get_build_options(w);
    set_working_directory(#filepath);
    make_directory_if_it_does_not_exist("out");

    modules_path := join(#filepath, "src/modules");
    modules_paths: [..] string;
    array_add(*modules_paths, modules_path);
    array_add(*modules_paths, ..options.import_path);
    options.import_path = modules_paths;

    options.output_path =  "out" ;
    options.output_executable_name = "mini-nginx";

    set_optimization(*options, .VERY_DEBUG);
    set_build_options(options, w);

    add_build_file(join("src", "main.jai", separator="/"), w);

    set_build_options_dc(.{do_output=false, output_path="out", output_executable_name="target"});
}

#import "Compiler";
#import "Basic";
#import "String";
#import "File";
