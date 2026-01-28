# Creates a test repo, and then runs f() inside it
function with_test_repo(f::Function)
    original_dir = pwd()
    test_dir = mktempdir()
    try
        cd(test_dir)

        # Initialize repo
        run(`git init --initial-branch=main`)
        run(`git config user.email "test@example.com"`)
        run(`git config user.name "Test User"`)

        # Create initial commit
        write("file.txt", "initial")
        run(`git add file.txt`)
        run(`git commit -m "Initial commit"`)

        # Run the user-provided function:
        f()
    finally
        cd(original_dir)
        rm(test_dir; force=true, recursive=true)
    end
end
