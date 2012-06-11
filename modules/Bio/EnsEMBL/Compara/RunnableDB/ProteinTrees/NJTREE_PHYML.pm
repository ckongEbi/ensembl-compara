=head1 LICENSE

  Copyright (c) 1999-2012 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

   http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <dev@ensembl.org>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::NJTREE_PHYML

=head1 DESCRIPTION

This Analysis/RunnableDB is designed to take ProteinTree as input
This must already have a multiple alignment run on it. It uses that alignment
as input into the NJTREE PHYML program which then generates a phylogenetic tree

input_id/parameters format eg: "{'protein_tree_id'=>1234}"
    protein_tree_id : use 'id' to fetch a cluster from the ProteinTree

=head1 SYNOPSIS

my $db           = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $njtree_phyml = Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::NJTREE_PHYML->new
  (
   -db         => $db,
   -input_id   => $input_id,
   -analysis   => $analysis
  );
$njtree_phyml->fetch_input(); #reads from DB
$njtree_phyml->run();
$njtree_phyml->output();
$njtree_phyml->write_output(); #writes to DB

=head1 AUTHORSHIP

Ensembl Team. Individual contributions can be found in the CVS log.

=head1 MAINTAINER

$Author$

=head VERSION

$Revision$

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with an underscore (_)

=cut

package Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::NJTREE_PHYML;

use strict;

use IO::File;
use File::Basename;
use File::Path;
use Time::HiRes qw(time gettimeofday tv_interval);
use Data::Dumper;

use Bio::EnsEMBL::Compara::AlignedMember;
use Bio::EnsEMBL::Compara::Member;
use Bio::EnsEMBL::Compara::Graph::NewickParser;
use Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::MSA;

use base ('Bio::EnsEMBL::Compara::RunnableDB::GeneTrees::StoreTree', 'Bio::EnsEMBL::Compara::RunnableDB::GeneTrees::StoreClusters');


sub param_defaults {
    return {
            'cdna'              => 1,   # always use cdna for njtree_phyml
            'bootstrap'         => 1,
		'check_split_genes' => 1,
            'store_tree_support'    => 1,
    };
}


sub fetch_input {
    my $self = shift @_;

    $self->check_if_exit_cleanly;

    $self->param('member_adaptor', $self->compara_dba->get_MemberAdaptor);
    $self->param('tree_adaptor', $self->compara_dba->get_GeneTreeAdaptor);

    my $protein_tree_id     = $self->param('protein_tree_id') or die "'protein_tree_id' is an obligatory parameter";
    my $protein_tree        = $self->param('tree_adaptor')->fetch_by_dbID( $protein_tree_id )
                                        or die "Could not fetch protein_tree with protein_tree_id='$protein_tree_id'";
    $protein_tree->print_tree(10) if($self->debug);

    $self->param('protein_tree', $protein_tree);
}


sub run {
  my $self = shift;

  $self->check_if_exit_cleanly;
  $self->run_njtree_phyml;
}


sub write_output {
    my $self = shift;

    $self->check_if_exit_cleanly;
    $self->store_genetree($self->param('protein_tree'));

    if ($self->param('store_intermediate_trees')) {
        foreach my $clusterset_id (qw(phyml-aa phyml-nt nj-dn nj-ds nj-mm)) {
            my $filename = sprintf('%s/interm.%s.nhx', $self->worker_temp_directory, $clusterset_id);
            next unless -e $filename;
            print STDERR "Found file $filename for clusterset $clusterset_id\n";
            my $clusterset = $self->fetch_or_create_clusterset($clusterset_id);
            my $newtree = $self->param('protein_tree')->deep_copy();
            # We don't need cigar lines
            foreach my $member (@{$newtree->get_all_Members}) {
                $member->cigar_line('');
            }
            $self->store_tree_into_clusterset($newtree, $clusterset);
            $self->parse_newick_into_tree($filename, $newtree);
            $newtree->print_tree(10);
            $self->store_genetree($newtree);
            $newtree->store_tag('merged_tree', $self->param('protein_tree_id'));
        }
    }
    if ($self->param('store_filtered_align')) {
        my $filename = sprintf('%s/filtalign.fa', $self->worker_temp_directory);
        if (-e $filename) {
            print STDERR "Found filtered alignment: $filename\n";
            my $clusterset = $self->fetch_or_create_clusterset('filtered-align');
            my $newtree = $self->param('protein_tree')->deep_copy();
            $self->store_tree_into_clusterset($newtree, $clusterset);
            foreach my $member (@{$newtree->get_all_Members}) {
                $member->stable_id(sprintf("%d_%d", $member->dbID, $self->param('use_genomedb_id') ? $member->genome_db_id : $member->taxon_id));
            }
            $newtree->load_cigars_from_fasta($filename, $newtree);
            $self->store_genetree($newtree);
            Bio::EnsEMBL::Compara::RunnableDB::ProteinTrees::MSA::_store_aln_tags($self, $newtree);
            $newtree->store_tag('merged_tree', $self->param('protein_tree_id'));
        }
    }

    if (defined $self->param('output_dir')) {
        system("zip -r -9 ".($self->param('output_dir'))."/".($self->param('protein_tree_id')).".zip ".$self->worker_temp_directory);
    }
    rmtree([$self->worker_temp_directory]);
}

sub DESTROY {
  my $self = shift;

  if(my $protein_tree = $self->param('protein_tree')) {
    printf("NJTREE_PHYML::DESTROY  releasing tree\n") if($self->debug);
    $protein_tree->release_tree;
    $self->param('protein_tree', undef);
  }

  $self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
}


##########################################
#
# internal methods
#
##########################################


sub run_njtree_phyml {
  my $self = shift;

    my $protein_tree = $self->param('protein_tree');

  my $starttime = time()*1000;

  if (scalar(@{$protein_tree->root->get_all_leaves}) < 3) {
    printf(STDERR "tree cluster %d has <3 proteins - can not build a tree\n", $protein_tree->root_id);
    return;
  }
  my $input_aln = $self->dumpTreeMultipleAlignmentToWorkdir ( $protein_tree->root );

  my $newick_file = $input_aln . "_njtree_phyml_tree.txt ";

  my $treebest_exe = $self->param('treebest_exe')
      or die "'treebest_exe' is an obligatory parameter";

  die "Cannot execute '$treebest_exe'" unless(-x $treebest_exe);

  my $species_tree_file = $self->get_species_tree_file();

    $self->compara_dba->dbc->disconnect_when_inactive(1);
  # ./njtree best -f spec-v4.1.nh -p tree -o $BASENAME.best.nhx \
  # $BASENAME.nucl.mfa -b 100 2>&1/dev/null

  if (1 == $self->param('bootstrap')) {
    my $comput_ok = 0;
    until ($comput_ok) {

    my $cmd = $treebest_exe;
    $cmd .= " best ";
    if(my $max_diff_lk = $self->param('max_diff_lk')) {
        $cmd .= " -Z $max_diff_lk";
    }
    if ($species_tree_file) {
      $cmd .= " -f ". $species_tree_file;
    }
    $cmd .= " ". $input_aln;
    $cmd .= " -p interm ";
    $cmd .= " -o " . $newick_file;
    if ($self->param('extra_args')) {
      $cmd .= " ".($self->param('extra_args')).' ';
    }
    my $logfile = $self->worker_temp_directory. "proteintree_". $protein_tree->root_id . ".log";
    my $errfile = $self->worker_temp_directory. "proteintree_". $protein_tree->root_id . ".err";
    $cmd .= " 1>$logfile 2>$errfile";
    #     $cmd .= " 2>&1 > /dev/null" unless($self->debug);

    my $worker_temp_directory = $self->worker_temp_directory;
    my $full_cmd = defined $worker_temp_directory ? "cd $worker_temp_directory; $cmd" : "$cmd";
    print STDERR "Running:\n\t$full_cmd\n" if($self->debug);

    if(my $rc = system($full_cmd)) {
      my $system_error = $!;

      if(my $segfault = (($rc != -1) and ($rc & 127 == 11))) {
          $self->throw("'$full_cmd' resulted in a segfault");
      }
      print STDERR "$full_cmd\n";
      open(ERRFILE, $errfile) or die "Could not open logfile '$errfile' for reading : $!\n";
	my $logfile = "";
	my $handled_failure = 0;
      while (<ERRFILE>) {
        if (!($_ =~ /^Large distance/)) {
	     $logfile .= $_;
        }
        if (($_ =~ /NNI/) || ($_ =~ /Optimize_Br_Len_Serie/) || ($_ =~ /Optimisation failed/) || ($_ =~ /Brent failed/))  {
	     $handled_failure = 1;
	  }
	}
	if ($handled_failure) {
	    # Increase the tolerance max_diff_lk in the computation

          my $max_diff_lk_value = $self->param('max_diff_lk') ?  $self->param('max_diff_lk') : 1e-5;
	    $max_diff_lk_value *= 10;
          $self->param('max_diff_lk', $max_diff_lk_value);
      }
      $self->throw("error running njtree phyml: $system_error\n$logfile");
    } else {
        $comput_ok = 1;
    }
    }
  } elsif (0 == $self->param('bootstrap')) {
    # first part
    # ./njtree phyml -nS -f species_tree.nh -p 0.01 -o $BASENAME.cons.nh $BASENAME.nucl.mfa
    my $cmd = $treebest_exe;
    $cmd .= " phyml -nS";
    if($species_tree_file) {
      $cmd .= " -f ". $species_tree_file;
    }
    $cmd .= " ". $input_aln;
    $cmd .= " -p 0.01 ";

    my $intermediate_newick_file = $input_aln . "_intermediate_njtree_phyml_tree.txt ";
    $cmd .= " -o " . $intermediate_newick_file;
    $cmd .= " 2>&1 > /dev/null" unless($self->debug);

    print("$cmd\n") if($self->debug);
    my $worker_temp_directory = $self->worker_temp_directory;
    if(system("cd $worker_temp_directory; $cmd")) {
      my $system_error = $!;
      $self->throw("Error running njtree phyml noboot (step 1 of 2) : $system_error");
    }
    # second part
    # nice -n 19 ./njtree sdi -s species_tree.nh $BASENAME.cons.nh > $BASENAME.cons.nhx
    $cmd = $treebest_exe;
    $cmd .= " sdi ";
    if ($species_tree_file) {
      $cmd .= " -s ". $species_tree_file;
    }
    $cmd .= " ". $intermediate_newick_file;
    $cmd .= " 1> " . $newick_file;
    $cmd .= " 2> /dev/null" unless($self->debug);

    print("$cmd\n") if($self->debug);
    my $worker_temp_directory = $self->worker_temp_directory;
    if(system("cd $worker_temp_directory; $cmd")) {
      my $system_error = $!;
      $self->throw("Error running njtree phyml noboot (step 2 of 2) : $system_error");
    }
  } else {
    $self->throw("NJTREE PHYML -- wrong bootstrap option");
  }

  $self->compara_dba->dbc->disconnect_when_inactive(0);
      #parse the tree into the datastucture:
  $self->parse_newick_into_tree( $newick_file, $self->param('protein_tree') );

  my $runtime = time()*1000-$starttime;

  $protein_tree->store_tag('NJTREE_PHYML_runtime_msec', $runtime);
}


1;
