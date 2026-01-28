using Test

# Load the backporter module functions
const original_ARGS = copy(ARGS)
empty!(ARGS)
include("../backporter.jl")
copy!(ARGS, original_ARGS)

@testset "PR detection and categorization" begin
    @testset "detect_version_from_branch" begin
        test_dir = mktempdir()
        original_dir = pwd()

        try
            cd(test_dir)

            # Initialize repo
            run(`git init`)
            run(`git config user.email "test@example.com"`)
            run(`git config user.name "Test User"`)

            # Create initial commit
            write("file.txt", "initial")
            run(`git add file.txt`)
            run(`git commit -m "Initial commit"`)

            # Test version detection from different branch names
            run(`git checkout -b backports-release-1.11`)
            @test detect_version_from_branch() == "1.11"

            run(`git checkout -b backport-release-1.12`)
            @test detect_version_from_branch() == "1.12"

            run(`git checkout -b release-1.13`)
            @test detect_version_from_branch() == "1.13"

            # Test no match
            run(`git checkout -b feature-branch`)
            @test detect_version_from_branch() === nothing

        finally
            cd(original_dir)
            rm(test_dir; force=true, recursive=true)
        end
    end

    @testset "detect_repo_from_remote" begin
        test_dir = mktempdir()
        original_dir = pwd()

        try
            cd(test_dir)

            # Initialize repo
            run(`git init`)
            run(`git config user.email "test@example.com"`)
            run(`git config user.name "Test User"`)

            # Create initial commit
            write("file.txt", "initial")
            run(`git add file.txt`)
            run(`git commit -m "Initial commit"`)

            # Test SSH URL
            run(`git remote add origin git@github.com:JuliaLang/julia.git`)
            @test detect_repo_from_remote() == "JuliaLang/julia"

            # Test HTTPS URL with .git
            run(`git remote set-url origin https://github.com/KristofferC/Backporter.git`)
            @test detect_repo_from_remote() == "KristofferC/Backporter"

        finally
            cd(original_dir)
            rm(test_dir; force=true, recursive=true)
        end
    end

    @testset "CLI argument parsing" begin
        # Test version flag
        options = parse_cli_args(["--version", "1.11"])
        @test options.version == "1.11"
        @test !options.dry_run
        @test !options.help

        # Test short version flag
        options = parse_cli_args(["-v", "1.12"])
        @test options.version == "1.12"

        # Test repo flag
        options = parse_cli_args(["--repo", "custom/repo"])
        @test options.repo == "custom/repo"

        # Test short repo flag
        options = parse_cli_args(["-r", "other/repo"])
        @test options.repo == "other/repo"

        # Test dry-run flag
        options = parse_cli_args(["--dry-run"])
        @test options.dry_run

        # Test short dry-run flag
        options = parse_cli_args(["-n"])
        @test options.dry_run

        # Test help flag
        options = parse_cli_args(["--help"])
        @test options.help

        # Test short help flag
        options = parse_cli_args(["-h"])
        @test options.help

        # Test test-commit flag
        options = parse_cli_args(["--test-commit", "abc123"])
        @test options.test_commit == "abc123"

        # Test short test-commit flag
        options = parse_cli_args(["-t", "def456"])
        @test options.test_commit == "def456"

        # Test audit flag
        options = parse_cli_args(["--audit"])
        @test options.audit

        # Test short audit flag
        options = parse_cli_args(["-a"])
        @test options.audit

        # Test no-validate-branch flag
        options = parse_cli_args(["--no-validate-branch"])
        @test !options.validate_branch

        # Test no-require-clean flag
        options = parse_cli_args(["--no-require-clean"])
        @test !options.require_clean

        # Test cleanup-pr flag
        options = parse_cli_args(["--cleanup-pr", "1234"])
        @test options.cleanup_pr == 1234
        @test options.audit  # cleanup-pr implies audit mode

        # Test combined flags
        options = parse_cli_args(["-v", "1.11", "-r", "JuliaLang/julia", "-n"])
        @test options.version == "1.11"
        @test options.repo == "JuliaLang/julia"
        @test options.dry_run
    end

    @testset "extract_pr_numbers_from_message" begin
        # Test single PR number
        msg = "Fix bug in parser (#1234)"
        prs = extract_pr_numbers_from_message(msg)
        @test prs == [1234]

        # Test multiple PR numbers
        msg = "Merge changes (#100) and (#200)"
        prs = extract_pr_numbers_from_message(msg)
        @test prs == [100, 200]

        # Test PR number in middle of message
        msg = """Some feature

This implements feature (#5678)
with more details."""
        prs = extract_pr_numbers_from_message(msg)
        @test prs == [5678]

        # Test no PR numbers
        msg = "Regular commit message"
        prs = extract_pr_numbers_from_message(msg)
        @test isempty(prs)
    end

    @testset "extract_merge_pr_from_message" begin
        # Test standard merge message
        msg = "Merge pull request #1234 from user/branch"
        pr = extract_merge_pr_from_message(msg)
        @test pr == 1234

        # Test no merge PR
        msg = "Regular commit (#5678)"
        pr = extract_merge_pr_from_message(msg)
        @test pr === nothing
    end
end
