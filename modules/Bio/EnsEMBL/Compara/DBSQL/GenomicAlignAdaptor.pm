
#
# Ensembl module for Bio::EnsEMBL::DBSQL::GenomicAlignAdaptor
#
# Cared for by Ewan Birney <birney@ebi.ac.uk>
#
# Copyright Ewan Birney
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::DBSQL::GenomicAlignAdaptor - DESCRIPTION of Object

=head1 SYNOPSIS

Give standard usage here

=head1 DESCRIPTION

Describe the object here

=head1 AUTHOR - Ewan Birney

This modules is part of the Ensembl project http://www.ensembl.org

Email birney@ebi.ac.uk

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::Compara::DBSQL::GenomicAlignAdaptor;
use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Compara::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::Compara::GenomicAlign;
use Bio::EnsEMBL::Compara::FeatureAwareAlignBlockSet;
use Bio::EnsEMBL::Compara::AlignBlockSet; 
@ISA = qw(Bio::EnsEMBL::Compara::DBSQL::BaseAdaptor);

# we inheriet new

sub fetch_by_dbID {
    my ($self,$id) = @_;

    return $self->fetch_GenomicAlign_by_dbID($id);
}


=head2 list_align_ids

 Title   : list_align_ids
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub list_align_ids{
   my ($self) = @_;

   my $sth = $self->prepare("select align_id from align");
   $sth->execute();

   my @out;
   while( my ($gid) = $sth->fetchrow_array ) {
       push(@out,$gid);
   }

   return @out;
}



=head2 fetch_GenomicAlign_by_dbID

 Title   : fetch_GenomicAlign_by_dbID
 Usage   :
 Function:
 Example :
 Reterns : #kailan: returns protein_id(can get protein_name (align_name)  from the align table)
 Args    :

got to fix this

=cut

sub fetch_GenomicAlign_by_dbID{
  my ($self,$dbid) = @_;
  #my ($self,$dbid, $align_name) = @_;

  return Bio::EnsEMBL::Compara::GenomicAlign->new( -align_id => $dbid, -adaptor => $self);
  #return Bio::EnsEMBL::Compara::GenomicAlign->new( -align_id => $dbid, -adaptor => $self, -align_name =>$align_name);
}

=head2 fetch_align_id_by_align_name

 Title   : fetch_align_id_by_align_name
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub fetch_align_id_by_align_name {
  my ($self,$align_name) = @_;
  
  unless (defined $align_name) {
    $self->throw("align_name must be defined as argument");
  }

  my $sth = $self->prepare("select align_id from align where align_name=\"$align_name\"");
  $sth->execute();
  my ($align_id) = $sth->fetchrow_array;
  return $align_id;
}


=head2 fetch_by_genomedb_dnafrag_list

 Title   : fetch_by_genomedb_dnafrag_list
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub fetch_by_genomedb_dnafrag_list{
   my ($self,$genomedb,$dnafrag_list) = @_;

   my $str;

   if( !defined $dnafrag_list || !ref $genomedb || !$genomedb->isa('Bio::EnsEMBL::Compara::GenomeDB') ) {
       $self->throw("Misformed arguments");
   }

   foreach my $id ( @{$dnafrag_list} ) {
       $str .= "'$id',";
   }
   $str =~ s/\,$//g;
   $str = "($str)";
   my $gid = $genomedb->dbID();

   if( !defined  $gid ) {
       $self->throw("Your genome db is not database aware");
   }

   my $sql = "select distinct(gab.align_id) from genomic_align_block gab,dnafrag d where d.name in $str and d.genome_db_id = $gid and d.dnafrag_id = gab.dnafrag_id";
   
   my $sth = $self->prepare($sql);

   $sth->execute();

   my @out;

   while( my ($gaid) = $sth->fetchrow_array ) {
       push(@out,$self->fetch_by_dbID($gaid));
   }
	    

   return @out;
}


=head2 get_AlignBlockSet
    
 Title   : get_AlignBlockSet
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_AlignBlockSet{
   my ($self,$align_id,$row_number) = @_;

   my %dnafraghash;
   my $dnafragadp = $self->db->get_DnaFragAdaptor;

   if( !defined $row_number ) {
       $self->throw("Must get AlignBlockSet by row number");
   }

   my $sth = $self->prepare("select b.align_start,b.align_end,b.dnafrag_id,b.raw_start,b.raw_end,b.raw_strand , b.perc_id, b.score  from genomic_align_block b where b.align_id = $align_id and b.align_row_id = $row_number order by align_start");
   $sth->execute;

   my $alignset  = Bio::EnsEMBL::Compara::AlignBlockSet->new();
#   my $core_db;
 
   while( my $ref = $sth->fetchrow_arrayref ) {
       my($align_start,$align_end,$raw_id,$raw_start,$raw_end,$raw_strand, $perc_id, $score) = @$ref;
       my $alignblock = Bio::EnsEMBL::Compara::AlignBlock->new();
       $alignblock->align_start($align_start);
       $alignblock->align_end($align_end);
       $alignblock->start($raw_start);
       $alignblock->end($raw_end);
       $alignblock->strand($raw_strand);
       $alignblock->perc_id($perc_id);
       $alignblock->score($score);
      
       
       if( ! defined $dnafraghash{$raw_id} ) {
	   $dnafraghash{$raw_id} = $dnafragadp->fetch_by_dbID($raw_id);
           #print "raw_di: $raw_id\n\n";
           #print "in GAdaptor:", $dnafragadp->fetch_by_dbID($raw_id);
	   #$alignset->core_adaptor($dnafraghash{$raw_id}->genomedb->ensembl_db);
       }

       $alignblock->dnafrag($dnafraghash{$raw_id});
       $alignset->add_AlignBlock($alignblock);
#       $core_db = $dnafraghash{$raw_id}->genomedb->ensembl_db; 
   }

   #$alignset->core_adaptor($core_db);

   return $alignset;
}



=head2 store

 Title   : store
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub store {
   my ($self,$aln,$align_id) = @_;

   if( !defined $aln || !ref $aln || !$aln->isa('Bio::EnsEMBL::Compara::GenomicAlign') ) {
       $self->throw("Must store with a GenomicAlign, not a $aln");
   }

   unless (defined $align_id) {
     $self->throw("An align_id must be specified and defined");
   }

   my $dnafragadp = $self->db->get_DnaFragAdaptor();

   foreach my $abs ( $aln->each_AlignBlockSet ) {
       foreach my $ab ( $abs->get_AlignBlocks ) {
	   if( !defined $ab->dnafrag ) {
	       $self->throw("Must have a dnafrag attached to alignblocks");
	   }
	   if( !defined $ab->dnafrag->dbID ) {
	       $dnafragadp->store_if_needed($ab->dnafrag);
	   }
       }
   }

   # store the alignment first

#   my $sth = $self->prepare("insert into align (score) values ('0.0')");
#   $sth->execute;
#   $aln->dbID($sth->{'mysql_insertid'});
#   my $align_id = $aln->dbID;

   # for each alignblockset, store the row and then the alignblocks themselves
   
   my $sth3 = $self->prepare("insert into genomic_align_block (align_id,align_start,align_end,align_row_id,dnafrag_id,raw_start,raw_end,raw_strand,score,perc_id,cigar_line) values (?,?,?,?,?,?,?,?,?,?,?)");

   foreach my $ab ( $aln->each_AlignBlockSet ) {
       my $sth2 = $self->prepare("insert into align_row (align_id) values ($align_id)");
       $sth2->execute();
       my $row_id = $sth2->{'mysql_insertid'};

       foreach my $a ( $ab->get_AlignBlocks ) {
	   $sth3->execute($align_id,
			  $a->align_start,
			  $a->align_end,
			  $row_id,
			  $a->dnafrag->dbID,
			  $a->start,
			  $a->end,
			  $a->strand,
                          $a->score,
                          $a->perc_id,
			  $a->cigar_string
			  );

       }
   }
    
   $aln->dbID($align_id);

   return $align_id;
}




=head2 fetch_by_dnafrag

 Title	 : fetch_by_dnafrag
 Usage	 :
 Function:
 Example :
 Returns : an array of Bio::EnsEMBL::Compara::GenomicAlign objects 
 Args 	 :


=cut

sub fetch_by_dnafrag{
   my ($self,$dnafrag) = @_;


   $self->throw("Input $dnafrag not a Bio::EnsEMBL::Compara::DnaFrag\n")
    unless $dnafrag->isa("Bio::EnsEMBL::Compara::DnaFrag"); 

   #formating the $dnafrag
	
   my $dname = $dnafrag->name;
		
	  $dname = "('$dname')";

  my $sql = "select distinct(gab.align_id) from genomic_align_block gab,dnafrag d where d.name in $dname and d.dnafrag_id = gab.dnafrag_id";
   
	  my $sth = $self->prepare($sql);

   $sth->execute();

   my @out;

   while( my ($gaid) = $sth->fetchrow_array ) {
       push(@out,$self->fetch_by_dbID($gaid));
   }
      	

   return @out;
}



1;
