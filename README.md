
# <img alt="Logo Flavours JDK" src="FJDK-Logo.png " width="150"/>

# Flavours-JDK
**FJDK** is a robust, lightweight, interactive command-line interface tool for managing multiple Java Development Kits (JDKs). It allows you to easily install, switch, and manage isolated workspaces for different projects, ensuring the right Java version is always available without polluting your system globally.

## 🚀 Features

- **Interactive UI**: Built-in interactive menus using fzf for selecting versions and workspaces.

- **Workspace Isolation**: Create named workspaces with specific JDK versions and bind them to project directories.

- **Global Mode Hijacking**: Temporarily override the global system Java with a workspace version.

- **Integrity Checks**: Automatic **SHA256** verification for downloads and local installations.

- **Extensibility**: Import existing system JDKs or install from local .tar.gz archives.

- **Auto-Update**: Self-updating mechanism via Git.

## 🛠 Prerequisites

Before installing **FJDK**, ensure you have the following dependencies installed on your system:

- curl
- git
- jq (Required for JSON parsing from Azul API)
- fzf (Required for interactive menus)
- tar

## 📦 Installation

1. **Clone the repository** to your home directory:

    git clone [git@github.com:src-rdgo/FlavoursJDK.git](git@github.com:src-rdgo/FlavoursJDK.git) ~/.fjdk && chmod +x ~/.fjdk/fjdk.sh


2. **Add FJDK to your shell config** (.bashrc, .zshrc, etc.):
    ```Bash
    # FJDK --------------------------------
        export FJDK_DIR="$HOME/.fjdk"
        export PATH="$FJDK_DIR/current/bin:$FJDK_DIR:$PATH"
        export JAVA_HOME="$FJDK_DIR/current"
        # Initialize FJDK (Optional but you should, if you want auto-path resolution on load)
        source "$FJDK_DIR/fjdk.sh"
    # FJDK --------------------------------
    ````

3. **Source your shell**:
    - Open a **new shell** or.. **Alternatively** you can just source your shell config in your current session with: 
        - `source ~/.zshrc` -> For zsh
        - `source ~/.bashrc` -> For bash

## 📖 Usage Guide

### Commands

| Basic Commands | Description | 
| ------------------------- | ------------------------------------------------------------------------- |
| `fjdk install <version>` | Installs a specific version (e.g., 17, 21) from Azul Zulu. | 
| `fjdk install -e <path>` | Installs a JDK from a local .tar.gz file. | 
| `fjdk use <version>` | Switches the active JDK version (Global or Workspace). | 
| `fjdk <list/ls>` | Lists locally installed and imported versions. | 
| `fjdk <list/ls> -remote` | Lists available versions for download via API. | 
| `fjdk using` | Shows the currently active Java version and context status. | 
| `fjdk remove <version>` | Uninstalls a specific JDK version. | 
| `fjdk import` | Imports a JDK already installed on your system. | 
| `fjdk update` | Checks and updates the FJDK tool itself. | 


| Workspace | Commands	
| ------------------------- | ------------------------------------------------------------------------- |
| `fjdk ws` | Opens the Interactive Workspace Manager (Select/Create/Enter). |
| `fjdk ws -exit` | Exits the current workspace (restores global context). |
| `fjdk ws -map` | Visualizes the tree of Workspaces and registered projects. |
| `fjdk ws -set <name>` | Manually creates a new workspace. |
| `fjdk ws -remove [name]` | Deletes a workspace configuration and folder. |
| `fjdk ws -gm` | Enables Global Mode (Hijacks system JDK with WS version). |
| `fjdk ws -add [path]` | Registers a directory (or current PWD) to the active workspace. |
| `fjdk ws -del [path]` | Unregisters a directory (or current PWD) from the active workspace. |

## 📥 Installation Examples

**Interactive Mode (Recommended)**:

- Just run install without arguments to search and select from the available list.

    ` fjdk install`

    Specific Version:

    `fjdk install 17`

**Install from Local File**:
- Install a manually downloaded .tar.gz archive. **FJDK** will verify the hash if provided.
    
    ( **You will be prompted** for the JDK SHA256 Hash info, just paste the code there if you have it. )

    `fjdk install -e /path/to/openjdk-21_linux-x64_bin.tar.gz`

## 🏗 Workspace Management

Workspaces are the core feature of **FJDK**. They allow you to associate specific directories with specific JDK versions.

1. ### Creating and Managing Workspaces

    - Open the interactive Workspace Manager:

        `fjdk ws`
        - If there is a directory added to the workspace, you will be able to chose the project interactively too. Uppon choosing, you will auto `cd <path/yourproject>` and your bash session will match your jdk preffered version. For it to change the main JDK, see the flag **Global Mode** below.

    - Or use flags for quick actions:

        - `fjdk ws -set <name>`: Creates a new workspace named <name>.

        - `fjdk ws -remove [name]`: Deletes a workspace configuration.

        - `fjdk ws -map`: Visualizes the tree of workspaces and bound directories.
            Ex:
            ```zsh
            FJDK Workspace Map
            🌎 Global [jdk-17.0.8] << CURRENT SHELL
            ├── 🏗️ Workspaces
                ├── OSDev [zulu-jdk-21.0.9]
                │   ├── /home/you/projects/OpenSource/anotherProject
                │   ├── /home/you/projects/example
                ├── PrivateProjects [Not Set]
            ```
        
    - ### 🌐 Global Mode ( JDK Hijack 🚨 )

        If you need a workspace's Java version to be available globally (outside the terminal session constraints) temporarily:

        `fjdk ws -gm`: This enables **Global Mode**, linking the system's global java command to the workspace's version.

    -  ### Exiting a Workspace

        `fjdk ws -exit`: To return to the **default** system/global Java environment:
2. ### **Binding Directories**

    - Navigate to your project folder and bind it to the active workspace:

        1. **Enter/Activate a workspace**:

            `fjdk ws` : Select your workspace from the list


        2. Once inside the workspace (shell prompt usually indicates context), register the current directory:

            `fjdk ws -add -dir`


        3. To unbind a directory:

            `fjdk ws -del -dir`

    
3.  ### 💀 **NULL JDK**
    ⚡**This is not a bug!** :  
        It's' a **security feature** (a Fail-Fast mechanism) of FJDK. Designed to ensure environment isolation.

    ```Bash
    $ Java -version
    $ ❌ FJDK Critical: The JDK for this workspace is missing.
    ```
    1. ### The concept:
        When you activate a workspace (`fjdk ws`), the script inserts that workspace's bin directory at the beginning of your PATH.

        If the JDK previously configured for this workspace has been uninstalled or moved, FJDK detects the broken link. To prevent your project from silently falling back to the System Java (which could cause silent compatibility errors), FJDK points the workspace to a "Null JDK".

    2. ### The Interceptor
        The "Null JDK" is not a real Java installation. It is a directory created by FJDK containing a fake bash script named java:

    3. **How does this happen?**
        1. You are inside an active Workspace.

        2. The workspace PATH takes precedence over the system PATH.

        3. The JDK configured for this workspace no longer exists.

        4. When you type java, the shell executes this warning script instead of a real java binary.

    4. **How to fix it**

        While inside the workspace (where the error occurs), simply define a valid version again with `fjdk use <version>`
        
        *(This will update the workspace's symbolic link to a real JDK installation, and the java command will return to normal operation.)*


## ⚙️ Configuration

FJDK stores its configuration and versions in ~/.fjdk by default.

- Versions: 

    - `~/.fjdk/versions` (Downloaded)
    - `~/.fjdk/external`(Imported)

- Config File: 
    - `~/.fjdk/config`

- Symlinks: 
    - `~/.fjdk/current` points to the active JDK.

## 🤝 Contributing

Contributions are welcome! Please fork the repository and create a pull request with your changes! 

## 📄 License

This project is licensed under the MIT License.
